# frozen_string_literal: true

RSpec.describe Flexr::Runtime::Location do
  def lexer_class(eager: false)
    Class.new(Flexr::Lexer) do
      token_kind :struct
      option :eager_columns if eager
      rule(/./) { emit :CHAR }
    end
  end

  it "defers column computation by default" do
    location = lexer_class.new("あ").next_token.location

    expect(location[:column_begin]).to be_nil
    expect(location.column_begin).to eq(1)
    expect(location.column_end).to eq(2)
  end

  it "computes columns eagerly when requested" do
    location = lexer_class(eager: true).new("あ").next_token.location

    expect(location[:column_begin]).to eq(1)
    expect(location[:column_end]).to eq(2)
  end
end
