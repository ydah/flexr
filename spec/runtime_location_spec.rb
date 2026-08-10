# frozen_string_literal: true

require "weakref"

RSpec.describe Flexr::Runtime::Location do
  def lexer_class(eager: false)
    Class.new(Flexr::Lexer) do
      token_kind :struct
      option :eager_columns if eager
      rule(/./) { emit :CHAR }
    end
  end

  def token_and_reference
    lexer = lexer_class.new("あ")
    [lexer.next_token, WeakRef.new(lexer)]
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

  it "does not retain the lexer through a lazy location" do
    token, reference = token_and_reference
    GC.start

    expect(reference.weakref_alive?).to be_falsy
    expect(token.location.column_begin).to eq(1)
    expect(token.location.column_end).to eq(2)
  end
end
