# frozen_string_literal: true

require "json"
require "stringio"

RSpec.describe "parser-state lexical ambiguity diagnostics" do
  let(:grammar) do
    <<~GRAMMAR
      %token PREFIX OTHER LEFT RIGHT LONG
      %%
      input: PREFIX LEFT | PREFIX RIGHT | OTHER LONG ;
      %%
    GRAMMAR
  end

  before do
    require "lrama"
  rescue LoadError
    skip "Lrama is needed to build parser-state fixtures"
  end

  def check(rules, *options)
    Dir.mktmpdir("flexr-parser-ambiguity-") do |directory|
      grammar_path = File.join(directory, "parser.y")
      spec_path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(grammar_path, grammar)
      File.binwrite(spec_path, <<~LEXER)
        require "flexr"
        class ParserAmbiguityLexer < Flexr::Lexer
        #{rules}
        end
      LEXER
      output = StringIO.new
      errors = StringIO.new
      status = Flexr::CLI.run(
        ["check", spec_path, "--lrama-grammar", grammar_path, "--format", "json", *options],
        out: output, err: errors
      )
      [status, output.string, errors.string]
    end
  end

  def ambiguity_diagnostics(rules)
    status, output, errors = check(rules)
    expect(status).to eq(0), errors
    JSON.parse(output).select { |item| item.fetch("code") == "FLEXR-W024" }
  end

  def after_prefix(diagnostics)
    diagnostics.find { |item| item.fetch("message").start_with?("parser state 1 ") }
  end

  it "reports a coallowed pair and the syntax path to its LR state" do
    diagnostics = ambiguity_diagnostics(<<~LEXER)
      rule("p", emit: :PREFIX)
      rule("o", emit: :OTHER)
      rule("a", emit: :LEFT)
      rule("a", emit: :RIGHT, priority: 1)
      rule("z", emit: :LONG)
    LEXER

    expect(after_prefix(diagnostics)).to include(
      "severity" => "warning",
      "message" => /lexer state :initial.*:LEFT.*:RIGHT/,
      "note" => 'example input: "a" (byte offset 0)',
      "help" => /parser path:.*PREFIX/
    )
    expect(diagnostics.map { |item| item.fetch("message") }).to all(
      satisfy { |message| !message.match?(/\Aparser state [02] /) }
    )
  end

  it "lets a longer skip rule suppress an apparent tie" do
    diagnostics = ambiguity_diagnostics(<<~LEXER)
      rule(/a(?=b)/, emit: :LEFT)
      rule(/a(?=b)/, emit: :RIGHT)
      rule("ab", skip: true)
    LEXER

    expect(diagnostics).to be_empty
  end

  it "ignores a longer rule that the current LR state excludes" do
    diagnostics = ambiguity_diagnostics(<<~LEXER)
      rule(/a(?=b)/, emit: :LEFT)
      rule(/a(?=b)/, emit: :RIGHT)
      rule("ab", emit: :LONG)
    LEXER

    expect(after_prefix(diagnostics)).to include("note" => 'example input: "ab" (byte offset 0)')
  end

  it "compares total length including trailing context" do
    diagnostics = ambiguity_diagnostics(<<~LEXER)
      rule("a", followed_by: "bc", emit: :LEFT)
      rule("ab", followed_by: "c", emit: :RIGHT)
    LEXER

    expect(after_prefix(diagnostics)).to include("note" => 'example input: "abc" (byte offset 0)')
  end

  it "uses the remapped keyword kind when filtering terminals" do
    diagnostics = ambiguity_diagnostics(<<~LEXER)
      rule(/[a-z]+/, emit: :LONG)
      keywords({"a" => :LEFT}, among: :LONG)
      rule("a", emit: :RIGHT)
    LEXER

    expect(after_prefix(diagnostics)).to include(
      "message" => /:LEFT.*:RIGHT/,
      "note" => 'example input: "a" (byte offset 0)'
    )
  end

  it "discards earlier body ends of a rule with the same total length" do
    diagnostics = ambiguity_diagnostics(<<~LEXER)
      rule(/ab?/, followed_by: /b?c/, emit: :RIGHT)
      keywords({"a" => :LEFT}, among: :RIGHT)
      rule("ab", followed_by: "c", emit: :RIGHT)
    LEXER

    expect(diagnostics).to be_empty
  end

  it "includes the prefix and scan offset when a tie requires lookbehind" do
    diagnostics = ambiguity_diagnostics(<<~LEXER)
      rule("q", skip: true)
      rule(/(?<=q)a/, emit: :LEFT)
      rule(/(?<=q)a/, emit: :RIGHT)
    LEXER

    expect(after_prefix(diagnostics)).to include("note" => 'example input: "qa" (byte offset 1)')
  end

  it "uses the earliest eligible body in shortest-match states" do
    diagnostics = ambiguity_diagnostics(<<~LEXER)
      rule("p", emit: :PREFIX)
      state :word, match: :shortest do
        rule("a", followed_by: "bc", emit: :LEFT)
        rule(/a(?=bc)/, emit: :RIGHT)
        rule("abc", emit: :LONG)
      end
    LEXER

    expect(after_prefix(diagnostics)).to include(
      "message" => /lexer state :word.*:LEFT.*:RIGHT/,
      "note" => 'example input: "abc" (byte offset 0)'
    )
  end

  it "fails warn-as-error for a contextual tie" do
    status, output, errors = check(<<~LEXER, "--warn-as-error")
      rule("a", emit: :LEFT)
      rule("a", emit: :RIGHT)
    LEXER

    expect(status).to eq(1), errors
    expect(JSON.parse(output)).to include(hash_including("code" => "FLEXR-W024"))
  end

  it "reports an inconclusive check when a tied action's token is opaque" do
    status, output, errors = check(<<~LEXER)
      rule("a", emit: :LEFT)
      rule("a", emits: [:LEFT, :RIGHT]) { emit(text == "a" ? :RIGHT : :LEFT) }
    LEXER

    expect(status).to eq(0), errors
    records = JSON.parse(output)
    expect(records).to include(hash_including("code" => "FLEXR-W025", "severity" => "warning"))
    expect(records).not_to include(hash_including("code" => "FLEXR-W024"))
  end

  it "rejects explicit evaluation" do
    status, _output, errors = check('rule("a", emit: :LEFT)', "--eval")
    expect(status).to eq(2)
    expect(errors).to match(/--lrama-grammar.*(?:static|--eval)/)
  end

  context "with precedence resolving a shift/reduce conflict" do
    let(:grammar) do
      <<~GRAMMAR
        %token B C
        %left A
        %%
        input: expr A | expr ;
        expr: A | A A rest ;
        rest: B | C ;
        %%
      GRAMMAR
    end

    it "reports paths only through selected parser transitions" do
      diagnostics = ambiguity_diagnostics(<<~LEXER)
        rule("a", emit: :A)
        rule("b", emit: :B)
        rule("b", emit: :C)
      LEXER

      expect(after_prefix(diagnostics)).to include("help" => "parser path: A •")
      expect(diagnostics).not_to include(hash_including("help" => /parser path: A A/))
    end
  end
end
