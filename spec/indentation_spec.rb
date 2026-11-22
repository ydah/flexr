# frozen_string_literal: true

require "json"
require "open3"
require "stringio"

RSpec.describe "lexer indentation" do
  let(:grammar) do
    Class.new(Flexr::Lexer) do
      token_kind :struct
      indentation newline: :NL, indent: :IN, dedent: :OUT, brackets: %w[() []], tab_width: 4
      rule(/\r?\n/, emit: :NL)
      rule(/[ \t]+/, skip: true)
      rule(/#[^\r\n]*/, skip: true)
      rule(/[a-z]+/, emit: :WORD)
      rule(/[()\[\]]/) { emit :BRACKET, :transformed }
      rule('"("') { emit :STRING, "(" }
    end
  end

  it "emits positioned layout tokens before the next content token on discarding inputs" do
    source = StringIO.new("root\n  child\n    deep\n  peer\nend")
    tokens = grammar.new(source, filename: "nested.layout", chunk_size: 1, retain_input: false).tokens

    expect(tokens.map(&:type)).to eq(%i[WORD NL IN WORD NL IN WORD NL OUT WORD NL OUT WORD])
    layout = tokens.select { |token| %i[IN OUT].include?(token.type) }
    expect(layout.map(&:value)).to eq([nil, nil, nil, nil])
    expect(layout.map { |token| token.location.to_h.values_at(:byte_begin, :byte_end, :line_begin, :column_begin) }).to eq(
      [[7, 7, 2, 3], [17, 17, 3, 5], [24, 24, 4, 3], [29, 29, 5, 1]]
    )
    expect(layout.map { |token| token.location.filename }.uniq).to eq(["nested.layout"])
  end

  it "uses tab stops and includes the indentation on the first line" do
    tokens = grammar.new("\tx\n    y\n\t z\nend").tokens
    expect(tokens.map(&:type)).to eq(%i[IN WORD NL WORD NL IN WORD NL OUT OUT WORD])
  end

  it "ignores blank and comment-only lines without changing levels" do
    source = "\n # before\nroot\n\n  # empty\n  child\n      # inside\n  next\n\nend\n# last"
    expect(grammar.new(source).tokens.map(&:type)).to eq(%i[WORD NL IN WORD NL WORD NL OUT WORD NL])
  end

  it "ignores newlines and indentation in nested brackets using the original lexeme" do
    source = "root\n  child(\nmore[\n      x\n]\n )\n  \"(\"\nend"
    expect(grammar.new(source).tokens.map(&:type)).to eq(
      %i[WORD NL IN WORD BRACKET WORD BRACKET WORD BRACKET BRACKET NL STRING NL OUT WORD]
    )
  end

  it "treats text assembled with more as the complete bracket lexeme" do
    lexer = Class.new(Flexr::Lexer) do
      indentation newline: :NL, indent: :IN, dedent: :OUT, brackets: ["()"]
      rule(/\n/, emit: :NL)
      rule(/ +/, skip: true)
      rule(/[a-z]+/, emit: :WORD)
      rule('"') do
        push(:quoted)
        more
      end
      state(:quoted) do
        rule("(") do
          pop
          emit :STRING, "("
        end
      end
    end.new("a\n \"(\nb")

    expect(lexer.tokens.map(&:first)).to eq(%i[WORD NL IN STRING NL OUT WORD])
  end

  it "reports an inconsistent dedent at the first visible token" do
    instance = grammar.new("root\n    child\n  wrong", filename: "invalid.layout")
    expect { instance.tokens }.to raise_error(Flexr::LexError, /indentation/) do |error|
      expect([error.filename, error.byte_pos, error.line]).to eq(["invalid.layout", 17, 3])
    end
  end

  it "flushes outstanding dedents at EOF before an explicit EOF token" do
    lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      indentation newline: :NL, indent: :IN, dedent: :OUT
      rule(/\n/, emit: :NL)
      rule(/ +/, skip: true)
      rule(/[a-z]/, emit: :WORD)
      on_eof { emit :END }
    end.new("a\n b\n  c", filename: "eof.layout")

    tokens = lexer.tokens
    expect(tokens.map(&:type)).to eq(%i[WORD NL IN WORD NL IN WORD OUT OUT END])
    expect(tokens[-3].location).to have_attributes(filename: "eof.layout", byte_begin: 8, byte_end: 8, line_begin: 3, column_begin: 4)
    expect(lexer.next_token).to be_nil
  end

  it "allows an EOF action to supply a final newline before dedent" do
    lexer = Class.new(Flexr::Lexer) do
      indentation newline: :NL, indent: :IN, dedent: :OUT
      rule(/\n/, emit: :NL)
      rule(/ +/, skip: true)
      rule(/[a-z]/, emit: :WORD)
      on_eof { emit :NL }
    end.new("a\n b")

    expect(lexer.tokens.map(&:first)).to eq(%i[WORD NL IN WORD NL OUT])
  end

  it "restores queued layout output from a checkpoint and allows a full rewind" do
    lexer = grammar.new("a\n b\nc")
    expect([lexer.next_token.type, lexer.next_token.type, lexer.next_token.type]).to eq(%i[WORD NL IN])
    checkpoint = lexer.checkpoint
    expected = lexer.tokens
    expect(lexer.restore(checkpoint).tokens).to eq(expected)
    expect { lexer.seek(2) }.to raise_error(ArgumentError, /indentation/)
    expect(lexer.seek(0).tokens.map(&:type)).to eq(%i[WORD NL IN WORD NL OUT WORD])
  end

  it "validates distinct token kinds, tab width, and disjoint bracket pairs" do
    invalid = [
      { newline: :NL, indent: :NL, dedent: :OUT },
      { newline: :NL, indent: :IN, dedent: :OUT, tab_width: 0 },
      { newline: :NL, indent: :IN, dedent: :OUT, brackets: ["()", "(]"] }
    ]
    invalid.each do |options|
      expect { Class.new(Flexr::Lexer) { indentation(**options) } }.to raise_error(Flexr::CompileError, /indentation/)
    end
  end

  it "matches layout with CRLF and newline tokens that consume indentation in runtime, generated, and standalone lexers" do
    Dir.mktmpdir("flexr-indentation") do |dir|
      source = File.join(dir, "lexer.flexr.rb")
      File.write(source, <<~'RUBY')
        require "flexr"
        class IndentationFixture < Flexr::Lexer
          BRACKETS = %w[() [] {}]
          indentation newline: :NL, indent: :IN, dedent: :OUT, brackets: BRACKETS, tab_width: 4
          rule(/\r?\n[ \t]*/, emit: :NL)
          rule(/[ \t]+/, skip: true)
          rule(/#[^\r\n]*/, skip: true)
          rule(/[a-z]+/, emit: :WORD)
        end
      RUBY
      variants = [[source, false]]
      %i[table direct firstmatch].product([false, true]).each do |backend, standalone|
        path = File.join(dir, "lexer.#{backend}.#{standalone}.rb")
        Flexr::Generator.new(source, output: path, options: { backend: backend, standalone: standalone }).generate
        variants << [path, standalone]
      end
      script = <<~'RUBY'
        require "json"
        require "stringio"
        load ARGV.fetch(0)
        input = StringIO.new("a\r\n\t# blank\r\n\tb\r\n    c\r\nz")
        puts JSON.generate(IndentationFixture.new(input, chunk_size: 1, retain_input: false).tokens)
      RUBY
      expected = [["WORD", "a"], ["NL", "\r\n\t"], ["IN", nil], ["WORD", "b"], ["NL", "\r\n    "],
                  ["WORD", "c"], ["NL", "\r\n"], ["OUT", nil], ["WORD", "z"]]

      variants.each do |path, standalone|
        command = [RbConfig.ruby]
        command.push("-Ilib") unless standalone
        stdout, stderr, status = Open3.capture3(*command, "-e", script, path)
        expect(status).to be_success, stderr
        expect(JSON.parse(stdout)).to eq(expected)
      end
    end
  end
end
