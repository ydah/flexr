# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

RSpec.describe "parser-state token selection" do
  let(:grammar_source) do
    <<~GRAMMAR
      %token IDENT DIV REGEXP
      %%
      input: IDENT DIV IDENT | REGEXP ;
      %%
    GRAMMAR
  end

  let(:rules) do
    <<~LEXER
      rule(/[a-z]+/, emit: :IDENT)
      rule(%r{/}, emit: :DIV)
      rule(%r{/[a-z]+/}, emit: :REGEXP)
    LEXER
  end

  before do
    require "lrama"
  rescue LoadError
    skip "Lrama is needed to build parser-state fixtures"
  end

  def with_parser_sources
    Dir.mktmpdir("flexr-parser-context-") do |directory|
      grammar = File.join(directory, "parser.y")
      source = File.join(directory, "lexer.flexr.rb")
      File.write(grammar, grammar_source)
      File.write(source, "require \"flexr\"\nclass ParserContextLexer < Flexr::Lexer\n#{rules}\nend\n")
      yield source, grammar, directory
    end
  end

  def run_parser_lexer(script, backend: :direct, standalone: false)
    with_parser_sources do |source, grammar, directory|
      artifact = File.join(directory, "lexer.rb")
      options = {lrama_grammar: grammar, backend: backend, standalone: standalone}
      Flexr::Generator.new(source, output: artifact, options: options).generate

      command = [RbConfig.ruby]
      command << "-Ilib" unless standalone
      environment = standalone ? {"RUBYOPT" => nil, "RUBYLIB" => nil} : {}
      runner = "require \"json\"\nrequire \"stringio\"\nload ARGV.fetch(0)\n#{script}"
      output, error, status = Open3.capture3(environment, *command, "-e", runner, artifact)
      expect(status).to be_success, error
      JSON.parse(output)
    end
  end

  %i[table direct].product([false, true]).each do |backend, standalone|
    it "chooses division after an identifier in #{backend} output with standalone=#{standalone}" do
      outcomes = run_parser_lexer(<<~RUBY, backend: backend, standalone: standalone)
        contextual = ParserContextLexer.new("x/name/".freeze)
        streamed = ParserContextLexer.new(StringIO.new("x/name/"), chunk_size: 1, retain_input: false)
        manual = ParserContextLexer.new("x/name/".freeze)
        states = [0, 1, 4]
        sets = [%i[IDENT REGEXP], [:DIV], [:IDENT]]
        puts JSON.generate([
          states.map { |state| contextual.next_token(parser_state: state) },
          states.map { |state| streamed.next_token(parser_state: state) },
          sets.map { |set| manual.next_token(expect: set) },
          contextual.next_token,
          contextual.next_token(parser_state: 3),
          ParserContextLexer.new("/name/").next_token(parser_state: 0),
          ParserContextLexer.new("/name/").next_token(parser_state: 2),
          Object.const_defined?(:Lrama, false)
        ])
      RUBY
      prefix = [%w[IDENT x], %w[DIV /], %w[IDENT name]]
      expect(outcomes).to eq([prefix, prefix, prefix, %w[DIV /], nil, %w[REGEXP /name/], %w[REGEXP /name/], false])
    end
  end

  it "rejects invalid IDs and conflicting expectation inputs before consuming a token" do
    outcomes = run_parser_lexer(<<~RUBY)
      scanner = ParserContextLexer.new("/name/")
      requests = [{parser_state: -1}, {parser_state: 700}, {parser_state: 2**1000},
                  {parser_state: "1"}, {parser_state: 1, expect: [:DIV]}]
      errors = requests.map do |request|
        begin
          scanner.next_token(**request)
        rescue ArgumentError
          "invalid"
        end
      end
      puts JSON.generate([errors, scanner.byte_pos, scanner.next_token])
    RUBY
    expect(outcomes).to eq([Array.new(5, "invalid"), 0, %w[REGEXP /name/]])
  end

  it "refuses to overwrite the grammar when it is also the output path" do
    with_parser_sources do |source, grammar, _directory|
      generator = Flexr::Generator.new(source, output: grammar, options: {lrama_grammar: grammar})

      expect { generator.generate }.to raise_error(ArgumentError, /refusing to overwrite input file/)
      expect(File.binread(grammar)).to eq(grammar_source)
    end
  end

  context "with an explicit nonassociative error alongside default reductions" do
    let(:grammar_source) do
      <<~'GRAMMAR'
        %token IDENT 258 "identifier"
        %token '+' 400
        %token '\n' 401
        %nonassoc '+'
        %%
        input: expression ;
        expression: expression '+' expression | IDENT ;
        %%
      GRAMMAR
    end

    let(:rules) do
      <<~'LEXER'
        rule("x", emit: :IDENT)
        rule("+", emit: :+)
        rule("\n", emit: :"\n")
      LEXER
    end

    it "permits a default reduction's terminals except explicit error actions" do
      outcomes = run_parser_lexer(<<~'RUBY')
        rejected_at = begin
          ParserContextLexer.new("+").next_token(parser_state: 6)
          raise "explicit parser error was accepted"
        rescue Flexr::LexError => error
          error.byte_pos
        end
        puts JSON.generate([
          ParserContextLexer.new("+").next_token(parser_state: 1),
          ParserContextLexer.new("x").next_token(parser_state: 6),
          ParserContextLexer.new("\n").next_token(parser_state: 6),
          rejected_at
        ])
      RUBY
      expect(outcomes).to eq([["+", "+"], %w[IDENT x], %W[\n \n], 0])
    end
  end

  context "when eligibility depends on the lexeme or lexical state" do
    let(:rules) do
      <<~LEXER
        token_kind :struct
        rule(" ", skip: true)
        rule("#", channel: :hidden, emit: :NOTE)
        rule(/[a-z]+/, emit: :IDENT)
        keywords({"if" => :REGEXP}, among: :IDENT)
        rule("!") { emit :OPAQUE, text }
        rule("?", emits: :DIV) { emit :DIV, text }

        state :raw, match: :shortest do
          rule(/^a/, followed_by: "bc", emit: :IDENT)
          rule("ab", emit: :REGEXP)
        end
      LEXER
    end

    it "matches manually supplied expectations through keyword remaps, trivia, and shortest matching" do
      outcomes = run_parser_lexer(<<~RUBY, standalone: true)
        def run(lexer, state, expected, contextual)
          token = contextual ? lexer.next_token(parser_state: state) : lexer.next_token(expect: expected)
          [token.type, token.value, token.leading_trivia.map(&:type)]
        end

        puts JSON.generate([true, false].map do |contextual|
          raw = ParserContextLexer.new(StringIO.new("abc"), chunk_size: 1)
          raw.begin_state(:raw)
          [
            run(ParserContextLexer.new(" #if"), 0, %i[IDENT REGEXP], contextual),
            run(ParserContextLexer.new("if"), 4, [:IDENT], contextual),
            run(ParserContextLexer.new("!"), 1, [:DIV], contextual),
            run(ParserContextLexer.new("?"), 1, [:DIV], contextual),
            run(raw, 0, %i[IDENT REGEXP], contextual)
          ]
        end)
      RUBY
      expected = [["REGEXP", "if", ["NOTE"]], ["IDENT", "i", []], ["OPAQUE", "!", []], ["DIV", "?", []], ["IDENT", "a", []]]
      expect(outcomes).to eq([expected, expected])
    end
  end

  context "when a rule asks for an unrestricted token" do
    let(:rules) do
      <<~LEXER
        rule(%r{/}, emit: :DIV)
        rule(%r{/[a-z]+/}, emit: :REGEXP)
        rule("@") do
          nested = next_token
          emit :IDENT, nested
        end
        rule("~") do
          begin_state(:raw)
          skip
        end

        state :raw do
          rule(%r{/}, emit: :DIV)
          rule(%r{/[a-z]+/}, emit: :REGEXP)
        end
      LEXER
    end

    it "scopes the requested state to one call and follows rule-driven state changes" do
      outcomes = run_parser_lexer(<<~RUBY)
        nested = ParserContextLexer.new("@/name//name/".freeze)
        switched = ParserContextLexer.new("~/name/".freeze)
        puts JSON.generate([
          nested.next_token(parser_state: 1),
          nested.next_token(parser_state: 1),
          switched.next_token(parser_state: 1),
          switched.state
        ])
      RUBY
      expect(outcomes).to eq([["IDENT", %w[REGEXP /name/]], %w[DIV /], %w[DIV /], "raw"])
    end
  end

  context "when a rule accepts a partial UTF-8 scalar" do
    let(:rules) do
      <<~'LEXER'
        rule(/\xC3/n, emit: :IDENT)
        rule("é", emit: :REGEXP)
      LEXER
    end

    it "uses the same UTF-8 boundary test as manual expectations" do
      outcomes = run_parser_lexer(<<~RUBY)
        input = "é".freeze
        outcomes = [{parser_state: 4}, {expect: [:IDENT]}].map do |options|
          begin
            ParserContextLexer.new(input).next_token(**options)
          rescue Flexr::LexError => error
            [error.class.name, error.byte_pos]
          end
        end
        puts JSON.generate(outcomes)
      RUBY
      expect(outcomes).to eq(Array.new(2, ["Flexr::LexError", 0]))
    end
  end

  context "when a parser-state scan reports incomplete input" do
    let(:rules) do
      <<~LEXER
        rule("ab", emit: :DIV)
        rule("ac", emit: :IDENT)
      LEXER
    end

    it "restricts error completions to the requested state's eligible rules" do
      outcomes = run_parser_lexer(<<~RUBY)
        input = "a".freeze
        outcomes = [{parser_state: 1}, {expect: [:DIV]}].map do |options|
          begin
            ParserContextLexer.new(input).next_token(**options)
          rescue Flexr::LexError => error
            [error.continuation.suffix, error.continuation.expected_bytes.map(&:begin)]
          end
        end
        puts JSON.generate(outcomes)
      RUBY
      expect(outcomes).to eq(Array.new(2, ["b", ["b".ord]]))
    end
  end
end
