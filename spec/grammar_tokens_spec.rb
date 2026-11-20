# frozen_string_literal: true

require "stringio"

RSpec.describe "grammar token integration" do
  around do |example|
    Dir.mktmpdir do |directory|
      @spec = File.join(directory, "lexer.flexr.rb")
      @grammar = File.join(directory, "parse.y")
      File.write(@spec, "class GrammarLexer < Flexr::Lexer\n  emits :INT, :PLUS, :EXTRA\n  rule(/a/, emit: :INT)\nend\n")
      File.write(@grammar, <<~GRAMMAR)
        %{ const char *text = "%token HIDDEN"; %}
        /* %token COMMENT */
        %token <value> INT 258 "integer"
          PLUS "+" MISSING
        %left PLUS
        %%
        expr: INT { /* %token ACTION */ };
        %%
      GRAMMAR
      example.run
    end
  end

  def run_cli(*args)
    output = StringIO.new
    errors = StringIO.new
    status = Flexr::CLI.run(args, out: output, err: errors)
    [status, output.string, errors.string]
  end

  it "compares only named token declarations and locates warnings in the specification" do
    status, output, errors = run_cli("check", @spec, "--grammar", @grammar, "--format", "json")
    expect(status).to eq(0), errors
    diagnostics = JSON.parse(output).select { |entry| %w[FLEXR-W017 FLEXR-W018].include?(entry["code"]) }
    expect(diagnostics.map { |entry| entry.fetch("message") }).to eq([
      "grammar token MISSING is not declared by emits", "emitted token EXTRA is not declared by the grammar"
    ])
    expect(diagnostics.all? { |entry| entry["location"].is_a?(Array) && entry["note"].include?(@grammar) }).to be(true)
    expect(run_cli("check", @spec, "--grammar", @grammar, "--warn-as-error").first).to eq(1)
    expect(run_cli("check", @spec, "--grammar", @grammar, "--warn", "none", "--format", "json")[1]).to eq("[]\n")
  end

  it "exports names as Lrama declarations and rejects names that cannot be exported" do
    expect(run_cli("tokens", @spec, "--format", "lrama")).to eq([0, "%token INT PLUS EXTRA\n", ""])
    File.write(@spec, "class GrammarLexer < Flexr::Lexer\n emits :'not-a-name'\nend\n")
    expect(run_cli("tokens", @spec, "--format", "lrama").first).to eq(2)
    expect(run_cli("stats", @spec, "--format", "lrama").first).to eq(2)
  end

  it "requires a grammar file and limits grammar checking to check" do
    expect(run_cli("check", @spec, "--grammar", "#{@grammar}.missing").first).to eq(1)
    expect(run_cli("tokens", @spec, "--grammar", @grammar).first).to eq(2)
  end
end
