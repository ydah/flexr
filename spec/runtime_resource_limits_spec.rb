# frozen_string_literal: true

class ResourceChunkedInput
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

RSpec.describe "Flexr runtime resource limits" do
  it "rejects less(0) instead of rescanning forever" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a/) do
        less(0)
        skip
      end
    end

    expect { lexer_class.new("a").tokens }
      .to raise_error(Flexr::Runtime::NonProgressError) { |error| expect(error.code).to eq("FLEXR-E021") }
  end

  it "detects an empty-match cycle across lexical states" do
    lexer_class = Class.new(Flexr::Lexer) do
      option :allow_empty_match
      rule(//) do
        begin_state :other
        skip
      end
      state :other do
        rule(//) do
          begin_state :initial
          skip
        end
      end
    end

    expect { lexer_class.new("a").tokens }.to raise_error(Flexr::Runtime::NonProgressError)
  end

  it "advances one codepoint for an allowed empty UTF-8 match" do
    lexer_class = Class.new(Flexr::Lexer) do
      option :allow_empty_match
      rule(//, skip: true)
    end
    lexer = lexer_class.new("あ")

    expect(lexer.tokens).to eq([])
    expect(lexer.byte_pos).to eq(3)
  end

  it "rejects less positions inside a UTF-8 codepoint" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/あ/) { less(1) }
    end

    expect { lexer_class.new("あ").tokens }.to raise_error(ArgumentError, /UTF-8 codepoint boundary/)
  end

  it "bounds trailing-context lookahead independently of token size" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a/, followed_by: /b+/) { emit :A }
      rule(/./) { skip }
    end

    expect { lexer_class.new("abbbb", max_token_size: 8, max_lookahead_size: 2).tokens }
      .to raise_error(Flexr::Runtime::LookaheadTooLargeError) do |error|
        expect(error.code).to eq("FLEXR-E024")
        expect(error.rule).to eq(0)
      end
  end

  it "bounds the retained streaming buffer" do
    input = ResourceChunkedInput.new("abcdef")
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/[a-z]+/) { emit :WORD }
    end

    expect { lexer_class.new(input, chunk_size: 2, max_buffer_size: 3).tokens }
      .to raise_error(Flexr::Runtime::BufferTooLargeError) { |error| expect(error.code).to eq("FLEXR-E022") }
    expect(input.reads.sum).to be <= 4
  end

  it "bounds scanning work with max_steps" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a+/) { emit :WORD }
    end

    expect { lexer_class.new("aaaa", max_steps: 2).tokens }
      .to raise_error(Flexr::Runtime::StepLimitError) { |error| expect(error.code).to eq("FLEXR-E023") }
  end

  it "bounds a long viable prefix before it reaches an accepting state" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a+x/) { emit :WORD }
    end

    expect { lexer_class.new("aaaa", max_token_size: 2).tokens }
      .to raise_error(Flexr::Runtime::TokenTooLargeError)
  end

  it "supports cooperative cancellation" do
    checks = 0
    cancellation = lambda do
      checks += 1
      checks >= 3
    end
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a+/) { emit :WORD }
    end

    expect { lexer_class.new("aaaa", cancellation: cancellation).tokens }
      .to raise_error(Flexr::Runtime::CancelledError) { |error| expect(error.code).to eq("FLEXR-E026") }
  end

  it "does not swallow exceptions raised by a cancellation callback during acceleration" do
    checks = 0
    cancellation = lambda do
      checks += 1
      raise ArgumentError, "callback failed" if checks >= 3

      false
    end
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a+/) { emit :WORD }
    end

    expect { lexer_class.new("aaaa", cancellation: cancellation).tokens }
      .to raise_error(ArgumentError, "callback failed")
  end

  it "releases consumed input with a sliding streaming buffer" do
    input = ResourceChunkedInput.new("aa aa aa aa")
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a+/) { emit :WORD, text }
      rule(/ /, skip: true)
    end
    lexer = lexer_class.new(input, chunk_size: 2, max_buffer_size: 4, retain_input: false)

    expect(lexer.tokens).to eq([[:WORD, "aa"]] * 4)
    expect(lexer.buffer.base_offset).to eq(11)
    expect(lexer.buffer.retained_bytesize).to eq(0)
    expect(lexer.input).to eq("")
  end

  it "rejects unknown recovery callback results" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a/) { emit :A }
    end
    lexer = lexer_class.new("?")
    lexer.on_error = ->(_error) { :continue }

    expect { lexer.next_token }.to raise_error(Flexr::Runtime::InvalidRecoveryActionError) do |error|
      expect(error.code).to eq("FLEXR-E027")
    end
  end

  it "enforces the same early token limit in generated scanners" do
    Dir.mktmpdir do |directory|
      source = File.join(directory, "resource.flexr.rb")
      output = File.join(directory, "resource.generated.rb")
      File.write(source, <<~RUBY)
        require "flexr"

        class GeneratedResourceLimitLexer < Flexr::Lexer
          rule(/a+/) do
            less(1)
            emit :WORD
          end
        end
      RUBY
      Flexr::Generator.new(source, output: output).generate
      load output

      expect { GeneratedResourceLimitLexer.new("aaaa", max_token_size: 2).tokens }
        .to raise_error(Flexr::Runtime::TokenTooLargeError) do |error|
          expect([error.code, error.rule]).to eq(["FLEXR-E012", 0])
        end
    ensure
      Object.send(:remove_const, :GeneratedResourceLimitLexer) if
        Object.const_defined?(:GeneratedResourceLimitLexer, false)
    end
  end
end
