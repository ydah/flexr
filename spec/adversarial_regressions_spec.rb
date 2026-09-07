# frozen_string_literal: true

RSpec.describe "adversarial regressions" do
  it "stops trailing-context refill at an incomplete UTF-8 EOF" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a/, followed_by: /b/, emit: :A)
      rule(/b/, emit: :B)
    end

    expect(lexer_class.new("ab\xC3".b, max_steps: 100).next_token).to eq([:A, "a"])
  end

  it "keeps regexp acceleration byte-aligned after UTF-8 characters" do
    lexer_class = Class.new(Flexr::Lexer) do
      accel :regexp
      rule(/é/, skip: true)
      rule(/a+/, emit: :A)
      rule(/X/, emit: :X)
      rule(/b/, followed_by: /c/, emit: :B)
    end

    expect(lexer_class.new("éaaaXaaaaaaa").tokens)
      .to eq([[:A, "aaa"], [:X, "X"], [:A, "aaaaaaa"]])
  end

  it "uses the longest trailing-context alternative" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a/, followed_by: /b|bc/, emit: :A)
      rule(/abc/, emit: :ABC)
      rule(/./, skip: true)
    end

    expect(lexer_class.new("abc").next_token).to eq([:A, "a"])

    anchored = Class.new(Flexr::Lexer) do
      rule(/a/, followed_by: /b$/, emit: :A)
      rule(/ab/, emit: :AB)
      rule(/./, skip: true)
    end
    expect(anchored.new("abc").next_token).to eq([:AB, "ab"])
    expect(anchored.new("ab").next_token).to eq([:A, "a"])
    expect(anchored.new("ab\n").next_token).to eq([:A, "a"])
  end

  it "resets unmatched text and tracks UTF-8 columns after newlines" do
    error_lexer = Class.new(Flexr::Lexer) { rule(/[a-z]+/, emit: :WORD) }
    location_lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/.+/m, emit: :TEXT)
    end

    expect(error_lexer.new("abc!", error_mode: :token).tokens)
      .to eq([[:WORD, "abc"], [:error, "!"]])
    location = location_lexer.new("あ\nx").next_token.location
    expect([location.line_end, location.column_end]).to eq([2, 2])
  end

  it "accepts callable cancellation objects without requiring arity" do
    cancellation = Class.new do
      def call
        true
      end
    end.new
    lexer_class = Class.new(Flexr::Lexer) { rule(/a/, emit: :A) }

    expect { lexer_class.new("a", cancellation: cancellation).next_token }
      .to raise_error(Flexr::Runtime::CancelledError)
  end

  it "honors scoped case options and hexadecimal bytes" do
    scoped_lexer = Class.new(Flexr::Lexer) do
      rule(/(?-i:a)/i, emit: :LOWER)
      rule(/A/, emit: :UPPER)
    end
    byte_escape_lexer = Class.new(Flexr::Lexer) do
      rule(/\xC3\xA9/, emit: :E_ACUTE)
    end

    expect(scoped_lexer.new("A").tokens).to eq([[:UPPER, "A"]])
    expect(byte_escape_lexer.new("é").tokens).to eq([[:E_ACUTE, "é"]])
  end

  it "preserves source bytes, configuration, actions, and EOF bindings when generating" do
    Dir.mktmpdir("flexr-adversarial-") do |directory|
      source = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      File.binwrite(source, <<~'RUBY')
        require "flexr"
        # 日本語
        class AdversarialGeneratedLexer < Flexr::Lexer
          encoding "BINARY"
          marker = :DONE
          rule(/\xFF/n) { emit :VALUES, [1, 2].reject(&:odd?) }
          rule(/a/) { emit :WORD, "reject" }
          on_eof { emit marker, "" }
        end
      RUBY

      Flexr::Generator.new(source, output: output).generate
      load output

      expect(AdversarialGeneratedLexer.new("\xFFa".b).tokens)
        .to eq([[:VALUES, [2]], [:WORD, "reject"], [:DONE, ""]])

      File.write(source, "class RejectedGeneratedLexer < Flexr::Lexer; rule(/a/) { reject }; end\n")
      expect { Flexr::Generator.new(source).generate }
        .to raise_error(Flexr::CompileError) { |error| expect(error.diagnostic.code).to eq("FLEXR-E013") }
    ensure
      Object.send(:remove_const, :AdversarialGeneratedLexer) if
        Object.const_defined?(:AdversarialGeneratedLexer, false)
    end
  end

end
