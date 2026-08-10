# frozen_string_literal: true

require "open3"
require "rbconfig"

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
    script = <<~RUBY
      require "flexr"
      require "weakref"

      def lexer_class
        Class.new(Flexr::Lexer) do
          token_kind :struct
          rule(/./) { emit :CHAR }
        end
      end

      def token_and_reference
        lexer = lexer_class.new("あ")
        [lexer.next_token, WeakRef.new(lexer)]
      end

      token, reference = token_and_reference
      GC.start
      abort "lexer retained" if reference.weakref_alive?
      abort "unexpected columns" unless [token.location.column_begin, token.location.column_end] == [1, 2]
    RUBY
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)

    expect(status).to be_success, stderr
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
end
