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

end
