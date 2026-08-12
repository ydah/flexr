# frozen_string_literal: true

require "objspace"

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

  it "does not retain the lexer through a lazy location" do
    lexer = lexer_class.new("あ")
    location = lexer.next_token.location

    expect(ObjectSpace.reachable_objects_from(location)).not_to include(lexer)
    expect(location.instance_variable_get(:@column_values)).to eq([1, 2])
  end

  it "spans the complete token assembled with more" do
    lexer_class = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/</) do
        more
        skip
      end
      rule(/[^>]+/) do
        more
        skip
      end
      rule(/>/) { emit :TEXT, text }
    end

    token = lexer_class.new("<ab>").next_token

    expect(token.value).to eq("<ab>")
    expect(token.location.to_h).to include(
      byte_begin: 0, byte_end: 4, line_begin: 1, line_end: 1
    )
    expect([token.location.column_begin, token.location.column_end]).to eq([1, 5])
  end

  it "tracks columns without rescanning a long input prefix" do
    input = "a" * 2_000
    lexer = lexer_class.new(input, retain_input: false)
    original_byteslice = lexer.buffer.method(:byteslice)
    sliced_bytes = 0
    lexer.buffer.define_singleton_method(:byteslice) do |*arguments|
      original_byteslice.call(*arguments).tap { |slice| sliced_bytes += slice.to_s.bytesize }
    end

    tokens = lexer.tokens

    expect(tokens.last.location.column_end).to eq(2_001)
    expect(sliced_bytes).to be < input.bytesize * 8
    expect(lexer.buffer.base_offset).to eq(input.bytesize)
  end
end
