# frozen_string_literal: true

require "json"
require "open3"
require "stringio"

RSpec.describe "parser token expectations" do
  it "filters longer DFA candidates and keeps skip rules eligible" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/ +/, skip: true)
      rule(%r{/[^/]+/}, emit: :REGEXP)
      rule("/", emit: :DIV)
      rule(/[a-z]+/, emit: :IDENT)
    end

    division = lexer.new(" /abc/")
    expect(division.next_token(expect: [:DIV])).to eq([:DIV, "/"])
    expect(division.next_token).to eq([:IDENT, "abc"])
    expect(division.next_token(expect: [:DIV])).to eq([:DIV, "/"])
    expect(lexer.new(" /abc/").next_token(expect: [:REGEXP])).to eq([:REGEXP, "/abc/"])
  end

  it "keeps unannotated actions eligible and filters declared action outputs" do
    dynamic = Class.new(Flexr::Lexer) do
      rule("ab") { emit :AB }
      rule("a", emit: :A)
    end
    annotated = Class.new(Flexr::Lexer) do
      rule("ab", emits: %i[AB]) { emit :AB }
      rule("a", emit: :A)
    end

    expect(dynamic.new("ab").next_token(expect: [:A])).to eq([:AB, "ab"])
    expect(annotated.new("ab").next_token(expect: [:A])).to eq([:A, "a"])
    expect(annotated.new("ab").next_token(expect: [:AB])).to eq([:AB, "ab"])
  end

  it "chooses the keyword type at each candidate's actual end" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/[a-z]+/, emit: :IDENT)
      rule("if", emit: :FALLBACK)
      keywords({ "if" => :IF, "then" => :THEN }, among: :IDENT)
    end

    expect(lexer.new("ifx").next_token(expect: [:IF])).to eq([:IF, "if"])
    expect { lexer.new("then").next_token(expect: [:IF]) }.to raise_error(Flexr::LexError)
    expect(lexer.new("if").next_token(expect: [:IDENT])).to eq([:IDENT, "i"])
    expect(lexer.new("if").next_token(expect: [:FALLBACK])).to eq([:FALLBACK, "if"])
  end

  it "consumes leading trivia while applying expectations through the Racc adapter" do
    lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/ +/, channel: :hidden, emit: :SPACE)
      rule("ab", emit: :AB)
      rule("a", emit: :A)
      rule("b", emit: :B)
    end

    token = lexer.new("  ab").next_token(expect: [:A])
    expect(token.type).to eq(:A)
    expect(token.leading_trivia.map(&:type)).to eq([:SPACE])
    instance = lexer.new("  ab")
    expect(instance.racc_next_token(expect: [:A])).to eq([:A, "a"])
    expect(instance.racc_next_token(expect: [:B])).to eq([:B, "b"])
    expect(instance.racc_next_token(expect: [])).to eq([false, "$end"])
  end

  it "uses anchored trailing context and source order on one-byte streaming input" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/^a/, followed_by: "bc", emit: :CONTEXT)
      rule("abc", emit: :LONG)
      rule("a", emit: :A)
    end

    expect(lexer.new(StringIO.new("abc"), chunk_size: 1).next_token(expect: %i[LONG CONTEXT])).to eq([:CONTEXT, "a"])
    expect(lexer.new(StringIO.new("abc"), chunk_size: 1).next_token(expect: [:LONG])).to eq([:LONG, "abc"])
    expect(lexer.new(StringIO.new("abc"), chunk_size: 1, max_lookahead_size: 0).next_token(expect: [:A])).to eq([:A, "a"])
  end

  it "breaks total-length ties by priority after filtering eligible rules" do
    lexer = Class.new(Flexr::Lexer) do
      rule("a", followed_by: "b", emit: :CONTEXT, priority: 2)
      rule("ab", emits: :AB, priority: 10) { emit :AB }
      rule("abc", emit: :LONG)
    end

    expect(lexer.new("abc").next_token(expect: %i[CONTEXT AB])).to eq([:AB, "ab"])
    expect(lexer.new("abc").next_token(expect: [:CONTEXT])).to eq([:CONTEXT, "a"])
    expect(lexer.new("abc").next_token(expect: %i[CONTEXT AB LONG])).to eq([:LONG, "abc"])
  end

  it "keeps native firstmatch rule and alternative order among eligible candidates" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule("ab", emit: :LONG)
      rule(/a|ab/, emit: :ALT)
      rule("ab", emit: :LATE)
    end

    expect(lexer.new("ab").next_token(expect: %i[LATE ALT])).to eq([:ALT, "a"])
    expect(lexer.new("ab").next_token).to eq([:LONG, "ab"])
  end

  it "avoids matching a statically excluded native firstmatch rule" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a+/, emit: :LONG)
      rule("a", emit: :SHORT)
    end

    expect(lexer.new("aaaa", max_token_size: 1).next_token(expect: [:SHORT])).to eq([:SHORT, "a"])
  end

  it "filters the keyword output of each native firstmatch pattern" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule([/ifx/, "if"], emit: :IDENT)
      keywords %w[if], among: :IDENT
    end

    expect(lexer.new("ifx").next_token).to eq([:IDENT, "ifx"])
    expect(lexer.new("ifx").next_token(expect: [:IF])).to eq([:IF, "if"])
  end

  it "validates the expected symbols and rule annotation" do
    lexer = Class.new(Flexr::Lexer) { rule("a", emit: :A) }.new("a")
    expect { lexer.next_token(expect: [:A, "B"]) }.to raise_error(ArgumentError, /expect:/)
    expect(lexer.byte_pos).to eq(0)
    expect(lexer.next_token(expect: nil)).to eq([:A, "a"])
    expect do
      Class.new(Flexr::Lexer) { rule("a", emits: ["A"]) { emit :A } }
    end.to raise_error(Flexr::CompileError, /emits:/)
    expect do
      Class.new(Flexr::Lexer) { rule("a", emit: :A, emits: :B) }
    end.to raise_error(Flexr::CompileError, /emits:/)
  end

  it "locates an invalid annotation in the static grammar" do
    Dir.mktmpdir("flexr-parser-annotation") do |dir|
      path = File.join(dir, "lexer.flexr.rb")
      source = <<~RUBY
        class BadParserAnnotation < Flexr::Lexer
          rule("a", emits: ["A"]) { emit :A }
        end
      RUBY
      File.write(path, source)

      expect { Flexr::Generator.new(path).generate }.to raise_error(Flexr::CompileError) do |error|
        start, finish = error.diagnostic.location
        expect(source.byteslice(start...finish)).to eq('["A"]')
      end
    end
  end

  it "filters a committed same-ABI scanner whose generated scan_one has no expectation support" do
    script = <<~RUBY
      require "json"
      require_relative "benchmark/golden/with_racc_lexer"
      lexer = WithRacc::RaccLexer.new("12+", error_mode: :panic)
      puts JSON.generate(lexer.next_token(expect: [:PLUS]))
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)
    expect(status).to be_success, stderr
    expect(JSON.parse(stdout)).to eq(["PLUS", "+"])
  end

  it "matches runtime, generated and standalone parser-visible tokens and trivia" do
    Dir.mktmpdir("flexr-parser-expectations") do |dir|
      source = File.join(dir, "lexer.flexr.rb")
      File.write(source, <<~RUBY)
        require "flexr"
        class ParserExpectationsFixture < Flexr::Lexer
          TEMPLATE_TYPES = %i[TEMPLATE_TEXT RAW]
          token_kind :struct
          rule(/ +/, channel: :hidden, emit: :SPACE)
          rule(/[a-z]+/, emit: :IDENT)
          keywords %w[return], among: :IDENT
          rule(%r{/[^/]+/}, emits: :REGEXP) { emit :REGEXP }
          rule("/", emit: :DIV)
          rule(/[^`$]+/, emits: TEMPLATE_TYPES) { emit :TEMPLATE_TEXT }
          rule('${', emit: :INTERPOLATE)
          rule('`', emit: :BACKTICK)
        end
      RUBY
      variants = [[source, false]]
      %i[table direct firstmatch].product([false, true]).each do |backend, standalone|
        path = File.join(dir, "lexer.#{backend}.#{standalone}.rb")
        Flexr::Generator.new(source, output: path, options: { backend: backend, standalone: standalone }).generate
        variants << [path, standalone]
      end
      script = <<~RUBY
        require "json"
        require "stringio"
        load ARGV.fetch(0)
        lexer = ParserExpectationsFixture.new(StringIO.new(" return /abc/ `hi${"), chunk_size: 1)
        sets = [%i[RETURN], %i[DIV], %i[IDENT], %i[DIV], %i[BACKTICK], %i[TEMPLATE_TEXT], %i[INTERPOLATE]]
        tokens = sets.map do |set|
          token = lexer.next_token(expect: set)
          [token.type, token.value, token.leading_trivia.map(&:type)]
        end
        literal = ParserExpectationsFixture.new("/abc/").next_token(expect: %i[REGEXP])
        puts JSON.generate([tokens, literal.type, literal.value])
      RUBY
      expected = [[
        ["RETURN", "return", ["SPACE"]], ["DIV", "/", ["SPACE"]], ["IDENT", "abc", []],
        ["DIV", "/", []], ["BACKTICK", "`", ["SPACE"]], ["TEMPLATE_TEXT", "hi", []], ["INTERPOLATE", '${', []]
      ], "REGEXP", "/abc/"]

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
