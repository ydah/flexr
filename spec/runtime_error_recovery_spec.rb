# frozen_string_literal: true

RSpec.describe "Flexr runtime error recovery" do
  let(:lexer_class) do
    Class.new(Flexr::Lexer) do
      rule(/a/) { emit :A }
    end
  end

  it "halts permanently when on_error returns :halt" do
    errors = []
    lexer = lexer_class.new("?a")
    lexer.on_error = lambda do |error|
      errors << error
      :halt
    end

    expect(lexer.next_token).to be_nil
    expect(lexer.next_token).to be_nil
    expect(lexer.tokens).to eq([])
    expect(errors.length).to eq(1)
  end

  it "continues after on_error returns :skip" do
    lexer = lexer_class.new("?a")
    lexer.on_error = ->(_error) { :skip }

    expect(lexer.tokens).to eq([[:A, "a"]])
  end

  it "raises the lexical error when on_error returns :raise" do
    lexer = lexer_class.new("?a")
    lexer.on_error = ->(_error) { :raise }

    expect { lexer.next_token }.to raise_error(Flexr::LexError)
    expect(lexer.next_token).to eq([:A, "a"])
  end

  it "returns one error token when on_error returns :token" do
    lexer = lexer_class.new("?a", error_mode: :raise)
    lexer.on_error = ->(_error) { :token }

    expect(lexer.tokens).to eq([[:error, "?"], [:A, "a"]])
  end

  it "keeps error_mode :token recovery without a callback" do
    expect(lexer_class.new("?a", error_mode: :token).tokens)
      .to eq([[:error, "?"], [:A, "a"]])
  end

  it "keeps error_mode :panic recovery without a callback" do
    expect(lexer_class.new("?a", error_mode: :panic).tokens).to eq([[:A, "a"]])
  end
end
