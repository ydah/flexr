# frozen_string_literal: true

class RuntimeChunkedInput
  attr_reader :reads

  def initialize(value)
    @value = value.dup
    @reads = []
  end

  def read(size)
    @reads << size
    return nil if @value.empty?

    chunk = @value.byteslice(0, [size, @value.bytesize].min)
    @value = @value.byteslice(chunk.bytesize..).to_s
    chunk
  end
end

RSpec.describe "Flexr runtime" do
  it "joins matches after more into the next token text" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/"/) do
        push :quoted
        more
        skip
      end

      state :quoted do
        rule(/[^"\\]+/) do
          more
          skip
        end
        rule(/"/) do
          emit :STRING, text
          pop
        end
      end
    end

    expect(lexer_class.new('"hello"').tokens).to eq([[:STRING, '"hello"']])
  end

  it "refills IO input without reading it all during initialization" do
    input = RuntimeChunkedInput.new("abcdef")
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/[a-z]+/) { emit :WORD, text }
    end

    lexer = lexer_class.new(input, chunk_size: 1)
    expect(input.reads).to be_empty
    expect(lexer.tokens).to eq([[:WORD, "abcdef"]])
    expect(input.reads.length).to be > 1
    expect(input.reads).to all(eq(1))
  end

  it "preserves UTF-8 encoding while refilling one byte at a time" do
    input = RuntimeChunkedInput.new("あいう")
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/\p{Hiragana}+/) { emit :WORD, text }
    end

    lexer = lexer_class.new(input, chunk_size: 1)
    expect(lexer.tokens).to eq([[:WORD, "あいう"]])
    expect(lexer.input.encoding).to eq(Encoding::UTF_8)
    expect(lexer.input.valid_encoding?).to be(true)
  end

  it "enforces max_token_size for reference matches" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/\p{Hiragana}+/) { emit :WORD, text }
    end

    expect { lexer_class.new("あいう", max_token_size: 2).tokens }
      .to raise_error(Flexr::Runtime::TokenTooLargeError)
  end

  it "enforces max_token_size in the firstmatch backend" do
    lexer_class = Class.new(Flexr::Lexer) do
      backend :firstmatch
      option :experimental
      rule(/a+/) { emit :WORD, text }
    end

    expect { lexer_class.new("aaaa", max_token_size: 3).tokens }
      .to raise_error(Flexr::Runtime::TokenTooLargeError)
  end

  it "raises when a token exceeds max_token_size, including a more prefix" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/"/) do
        more
        skip
      end
      rule(/[a-z]+/) do
        more
        skip
      end
      rule(/!/) do
        emit :TEXT, text
      end
    end

    expect { lexer_class.new('"abcd!', max_token_size: 4).tokens }
      .to raise_error(Flexr::Runtime::TokenTooLargeError)
  end

  it "protects the state stack with a configurable limit" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a/) do
        push :nested
        push :nested
      end
      state :nested do
        rule(/b/) { skip }
      end
    end

    expect { lexer_class.new("a", max_state_stack: 1).tokens }
      .to raise_error(Flexr::Runtime::StateStackOverflowError)
  end

  it "restarts EOF processing after an EOF action changes state" do
    lexer_class = Class.new(Flexr::Lexer) do
      on_eof { begin_state :finished }

      state :finished do
        on_eof { emit :EOF, :finished }
      end
    end

    lexer = lexer_class.new("")
    expect(lexer.tokens).to eq([%i[EOF finished]])
    expect(lexer.next_token).to be_nil
  end

  it "turns invalid UTF-8 bytes into ordinary unmatched-byte errors" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/./) { emit :CHAR }
    end
    input = "\xff".b.force_encoding(Encoding::UTF_8)

    expect(lexer_class.new(input, error_mode: :token).tokens).to eq([[:error, input]])
  end

  it "continues after unmatched bytes in panic mode" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/[a-z]+/) { emit :WORD }
    end

    expect(lexer_class.new("!ok", error_mode: :panic).tokens).to eq([[:WORD, "ok"]])
  end

  it "accepts a token exactly at max_token_size" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a+/) { emit :WORD, text }
    end

    expect(lexer_class.new("aaaa", max_token_size: 4).tokens).to eq([[:WORD, "aaaa"]])
  end

  it "enforces max_token_size after less has shortened the match" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a+/) do
        less(2)
        emit :WORD, text
      end
    end

    expect(lexer_class.new("aaaa", max_token_size: 2).tokens).to eq([[:WORD, "aa"], [:WORD, "aa"]])
  end
end
