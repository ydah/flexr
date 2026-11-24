# frozen_string_literal: true

require "stringio"

RSpec.describe "stable firstmatch backend" do
  it "selects the first matching rule without an experimental opt-in" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a/) { emit :A }
      rule(/ab/) { emit :AB }
      rule(/b/) { emit :B }
    end
    ["ab", StringIO.new("ab")].each do |input|
      expect(lexer.new(input, chunk_size: 1).tokens).to eq([[:A, "a"], [:B, "b"]])
    end
    expect(lexer.compile!.diagnostics.map(&:code)).to include("FLEXR-W010")
  end

  it "keeps an earlier longer alternative eligible across chunk boundaries" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/abc|a/, emit: :WORD)
      rule(/./m, emit: :OTHER)
    end

    expected = [[:WORD, "abc"], [:WORD, "a"], [:OTHER, "b"]]
    expect(lexer.new("abcab").tokens).to eq(expected)
    [1, 2, 3].each do |chunk_size|
      input = StringIO.new("abcab")
      expect(lexer.new(input, chunk_size: chunk_size, retain_input: false).tokens).to eq(expected)
    end
  end

  it "does not count ordered instructions against the DFA state limit" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/abc|a/, emit: :WORD)
    end
    lexer.__flexr_config.options[:max_dfa_states] = 4

    expect(lexer.new(StringIO.new("abc"), chunk_size: 1).next_token).to eq([:WORD, "abc"])
  end

  it "returns a higher priority short branch without reading the rest of a possible longer branch" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a|a+z/, emit: :WORD)
    end

    input = StringIO.new("a" * 100)
    expect(lexer.new(input, chunk_size: 1, max_buffer_size: 2).next_token).to eq([:WORD, "a"])
  end

  it "keeps a greedy repeated group eligible across chunk boundaries" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a(?:bc)*/, emit: :WORD)
      rule(/./m, emit: :OTHER)
    end

    value = "abcbcx"
    expected = [[:WORD, "abcbc"], [:OTHER, "x"]]
    expect(lexer.new(value).tokens).to eq(expected)
    expect(lexer.new(StringIO.new(value), chunk_size: 1).tokens).to eq(expected)
  end

  it "stops a growing token at the token limit before filling the buffer" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a+/, emit: :WORD)
    end

    input = StringIO.new("a" * 20)
    expect { lexer.new(input, chunk_size: 2, max_token_size: 3, max_buffer_size: 5).next_token }
      .to raise_error(Flexr::Runtime::TokenTooLargeError)
  end

  it "checks a terminal line end without using the lookahead budget" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/(?:a\n|a)$/, emit: :LINE_END)
      rule(/./m, emit: :OTHER)
    end

    input = StringIO.new("a\nb")
    expect(lexer.new(input, chunk_size: 1, max_lookahead_size: 0).next_token).to eq([:LINE_END, "a"])
  end

  it "uses ordered alternatives and byte matches on binary streams" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      encoding Encoding::BINARY
      rule(/\xffab|\xff/n) { emit :WORD, text.bytes }
      rule(/./m) { emit :BYTE, text.bytes }
    end

    value = "\xffab\xfe".b
    expected = [[:WORD, [255, 97, 98]], [:BYTE, [254]]]
    expect(lexer.new(value).tokens).to eq(expected)
    expect(lexer.new(StringIO.new(value), chunk_size: 1).tokens).to eq(expected)
  end

  it "preserves native Unicode case-fold matches in ordinary firstmatch rules" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/(?i:ss)/, emit: :WORD)
      rule(/ﬁ/i, emit: :LIGATURE)
      rule(/./m, emit: :OTHER)
    end

    expected = [[:WORD, "ß".bytes], [:LIGATURE, "fi".bytes]]
    ["ßfi", StringIO.new("ßfi")].each do |input|
      tokens = lexer.new(input, chunk_size: 1).tokens.map { |type, lexeme| [type, lexeme.bytes] }
      expect(tokens).to eq(expected)
    end
  end

  it "keeps generated firstmatch behavior without an experimental option" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      File.write(path, <<~RUBY)
        class StableFirstmatchFixture < Flexr::Lexer
          backend :firstmatch
          rule(/a|ab/) { emit :A }
          rule(/b/) { emit :B }
          rule([/c+/, /defg|de/], emit: :WORD)
        end
      RUBY
      Flexr::Generator.new(path, output: output).generate
      load output
      expect(StableFirstmatchFixture.new("ab").tokens).to eq([[:A, "a"], [:B, "b"]])
      input = StringIO.new("defg")
      expect(StableFirstmatchFixture.new(input, chunk_size: 1).next_token).to eq([:WORD, "defg"])
    ensure
      Object.send(:remove_const, :StableFirstmatchFixture) if Object.const_defined?(:StableFirstmatchFixture, false)
    end
  end
end
