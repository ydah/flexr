# frozen_string_literal: true

require "stringio"

RSpec.describe "runtime lexical error continuations" do
  it "reports matchable bytes at the mismatch and keeps the recovery position" do
    lexer = Class.new(Flexr::Lexer) { rule(/ab[cd]/, emit: :WORD) }

    expect { lexer.new("ab!").next_token }.to raise_error(Flexr::LexError) do |error|
      expect(error).to have_attributes(byte_pos: 0, text: "a", message: 'unexpected byte "a"')
      expect(error).to have_attributes(continuation: have_attributes(
        byte_pos: 2, expected_bytes: [0x63..0x64], suffix: "c", eof: false
      ))
      expect(error.diagnostic).to have_attributes(
        location: [2, 3], message: 'unexpected input "!"', help: 'complete the matched prefix with "c"'
      )
    end
    expect(lexer.new("abc").next_token).to eq([:WORD, "abc"])
  end

  it "reports an insertion point for an unfinished token after streamed UTF-8 input" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/😀|\n/, skip: true)
      rule(/"[^"]*"/, emit: :STRING)
    end
    input = "😀\n\"abc"
    scanner = lexer.new(StringIO.new(input), chunk_size: 1, retain_input: false)

    expect { scanner.next_token }.to raise_error(Flexr::LexError) do |error|
      expect(error).to have_attributes(byte_pos: 5, line: 2)
      expect(error.continuation).to have_attributes(byte_pos: 9, suffix: '"', eof: true)
      expect(error.diagnostic).to have_attributes(location: [9, 9], message: "unexpected end of input", help: 'append "\""')
      expect(lexer.new(input + error.continuation.suffix).next_token).to eq([:STRING, '"abc"'])
    end
  end

  it "preserves the matched part of a positive lookahead or trailing context" do
    lookahead = Class.new(Flexr::Lexer) { rule(/foo(?=bar)/, emit: :FOO) }
    trailing = Class.new(Flexr::Lexer) { rule("foo", followed_by: /bar/, emit: :FOO) }

    [lookahead, trailing].each do |lexer|
      expect { lexer.new("foob").next_token }.to raise_error(Flexr::LexError) do |error|
        expect(error.continuation).to have_attributes(byte_pos: 4, expected_bytes: [0x61..0x61], suffix: "ar", eof: true)
        expect(lexer.new("foob#{error.continuation.suffix}").next_token).to eq([:FOO, "foo"])
      end
    end
  end

  it "does not split a UTF-8 scalar in the diagnostic range" do
    lexer = Class.new(Flexr::Lexer) { rule("êz", emit: :WORD) }

    expect { lexer.new("éz").next_token }.to raise_error(Flexr::LexError) do |error|
      expect(error.continuation.byte_pos).to eq(1)
      expect(error.continuation.suffix.bytes).to eq([0xaa, 0x7a])
      expect(error.diagnostic).to have_attributes(location: [0, 2], message: 'unexpected input "é"')
    end
  end

  it "can finish a UTF-8 scalar split by end of input" do
    lexer = Class.new(Flexr::Lexer) { rule("é", emit: :WORD) }
    input = "\xc3".b

    expect { lexer.new(input).next_token }.to raise_error(Flexr::LexError) do |error|
      continuation = error.continuation
      expect(continuation).to have_attributes(byte_pos: 1, expected_bytes: [0xa9..0xa9], eof: true)
      expect(lexer.new(input + continuation.suffix).next_token.first).to eq(:WORD)
    end
  end

  it "keeps the diagnostic at the character start when the buffer holds only its leading byte" do
    lexer = Class.new(Flexr::Lexer) { rule("abcé", emit: :WORD) }
    scanner = lexer.new(StringIO.new("abc😀"), chunk_size: 1, retain_input: false)

    expect { scanner.next_token }.to raise_error(Flexr::LexError) do |error|
      expect(error.continuation).to have_attributes(byte_pos: 3, suffix: "é", eof: false)
      expect(error.diagnostic.location).to eq([3, 3])
    end
    expect(scanner.buffer.bytesize).to eq(4)
  end

  it "uses the parser's expected keyword when reporting candidate bytes" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/[a-z]+/, emit: :WORD)
      keywords({"if" => :IF}, among: :WORD)
    end

    expect { lexer.new("i").next_token(expect: [:IF]) }.to raise_error(Flexr::LexError) do |error|
      expect(error.continuation).to have_attributes(byte_pos: 1, expected_bytes: [0x66..0x66], suffix: "f")
    end
  end

  it "reports an empty completion when the matched prefix only accepts at EOF" do
    lexer = Class.new(Flexr::Lexer) { rule(/a\z/, emit: :WORD) }

    expect { lexer.new("ab").next_token }.to raise_error(Flexr::LexError) do |error|
      expect(error.continuation).to have_attributes(byte_pos: 1, expected_bytes: [], suffix: "", eof: false)
    end
  end

  it "keeps the callback's one-byte recovery and gives it the continuation data" do
    lexer = Class.new(Flexr::Lexer) { rule(/ab[cd]/, emit: :WORD) }
    scanner = lexer.new("ab!")
    scanner.on_error = lambda do |error|
      expect(error.continuation).to have_attributes(byte_pos: 2, suffix: "c")
      :token
    end

    expect(scanner.next_token).to eq([:error, "a"])
    expect(scanner.byte_pos).to eq(1)
  end

  it "finds a continuation without another read after a mismatch" do
    lexer = Class.new(Flexr::Lexer) { rule("abc", emit: :WORD) }
    input = StringIO.new("ab!")
    allow(input).to receive(:read).once.and_call_original

    expect { lexer.new(input, chunk_size: 3).next_token }.to raise_error(Flexr::LexError) do |error|
      expect(error.continuation).to have_attributes(byte_pos: 2, suffix: "c", eof: false)
    end
  end

  it "rebases a completion inside a delegated capture" do
    child = Class.new(Flexr::Lexer) { rule("abc", emit: :WORD) }
    parent = Class.new(Flexr::Lexer) do
      rule(/\[(?<code>[a-z]+)\]/) { delegate child, capture: :code }
    end

    expect { parent.new("[ab]", filename: "outer.txt").next_token }.to raise_error(Flexr::LexError) do |error|
      expect(error).to have_attributes(byte_pos: 1, filename: "outer.txt")
      expect(error.continuation).to have_attributes(byte_pos: 3, suffix: "c", eof: true)
      expect(error.diagnostic.location).to eq([3, 3])
    end
  end

  it "keeps EOF actions and explicit action errors independent of DFA completions" do
    lexer = Class.new(Flexr::Lexer) do
      rule("a") { error!("action error") { raise "unexpected block execution" } }
      on_eof { emit :END }
    end

    expect(lexer.new("").next_token).to eq([:END, ""])
    expect { lexer.new("a").next_token }.to raise_error(Flexr::LexError, "action error") do |error|
      expect(error.continuation).to be_nil
    end
  end
end
