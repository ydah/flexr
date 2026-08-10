# frozen_string_literal: true

require "stringio"

RSpec.describe Flexr::CLI do
  let(:spec_path) { File.expand_path("fixtures/generated.flexr.rb", __dir__) }

  def run_cli(*arguments)
    output = StringIO.new
    errors = StringIO.new
    status = described_class.run(arguments, out: output, err: errors)
    [status, output.string, errors.string]
  end

  it "accepts the documented validation and generation flags" do
    status, output, errors = run_cli(
      "check", spec_path,
      "--backend", "direct", "--token-kind", "struct", "--accel", "none",
      "--standalone", "--table-compression", "rows", "--table-format", "packed",
      "--max-dfa-states", "100", "--warn", "none", "--color", "never", "--format", "json"
    )

    expect(status).to eq(0)
    expect(output).to eq("[]\n")
    expect(errors).to be_empty
  end

  it "returns usage failure for unknown flags" do
    status, _output, errors = run_cli("check", spec_path, "--not-a-real-flag")

    expect(status).to eq(2)
    expect(errors).to include("unknown option")
  end

  it "imports a basic flex specification into ordinary Ruby" do
    path = File.join(Dir.tmpdir, "flexr-import-#{Process.pid}.l")
    File.write(path, <<~LEX)
      %x STRING
      %token WORD
      %%
      [a-z]+    { return WORD; }
      "<"       { BEGIN(STRING); }
      <STRING>[^>]+  ECHO;
      %%
      /* footer */
    LEX

    status, output, errors = run_cli("import", path)

    expect(status).to eq(0)
    expect(output).to include("class Lexer < Flexr::Lexer", "emits :WORD", "begin_state :STRING")
    expect(output).not_to include("FLEXR-TODO")
    expect(errors).to be_empty
  ensure
    FileUtils.rm_f(path)
  end

  it "keeps flex yylineno imports complete because Flexr tracks lines by default" do
    path = File.join(Dir.tmpdir, "flexr-yylineno-import-#{Process.pid}.l")
    File.write(path, <<~LEX)
      %option yylineno
      %%
      .    { value = lineno; return TOKEN; }
    LEX

    status, output, errors = run_cli("import", path)

    expect(status).to eq(0)
    expect(output).to include("value = lineno", "emit :TOKEN")
    expect(errors).to be_empty
  ensure
    FileUtils.rm_f(path)
  end

  it "keeps unknown flex options explicit and incomplete" do
    path = File.join(Dir.tmpdir, "flexr-unknown-option-import-#{Process.pid}.l")
    File.write(path, <<~LEX)
      %option yylineno noyywrap
      %%
      .    ;
    LEX

    status, _output, errors = run_cli("import", path)

    expect(status).to eq(1)
    expect(errors).to include("unsupported flex option noyywrap")
  ensure
    FileUtils.rm_f(path)
  end

  it "reports a concrete Rexical first-match counterexample" do
    path = File.join(Dir.tmpdir, "flexr-rexical-import-#{Process.pid}.rex")
    File.write(path, <<~REX)
      class RexicalFixture
        rule
          /a/  { return A; }
          /aa/ { return AA; }
        end
      end
    REX

    status, output, errors = run_cli("import", path)

    expect(status).to eq(0)
    expect(output).to include("emit :A", "emit :AA")
    expect(errors).to include("Rexical uses first-match semantics",
                              "Rexical rules 0 and 1",
                              '"aa" is a counterexample')
  ensure
    FileUtils.rm_f(path)
  end

  it "does not claim a Rexical semantic difference without a witness" do
    path = File.join(Dir.tmpdir, "flexr-rexical-no-witness-#{Process.pid}.rex")
    File.write(path, <<~REX)
      rule
        /a/ { return A; }
        /b/ { return B; }
      end
    REX

    status, _output, errors = run_cli("import", path)

    expect(status).to eq(0)
    expect(errors).to include("Rexical uses first-match semantics")
    expect(errors).not_to include("counterexample")
  ensure
    FileUtils.rm_f(path)
  end

  it "fails incomplete imports instead of silently accepting untranslated C" do
    path = File.join(Dir.tmpdir, "flexr-incomplete-import-#{Process.pid}.l")
    File.write(path, <<~LEX)
      %%
      .    { printf("%s", yytext); }
    LEX

    status, output, errors = run_cli("import", path)

    expect(status).to eq(1)
    expect(output).to include("FLEXR-TODO")
    expect(errors).to include("manual action translation required")
  ensure
    FileUtils.rm_f(path)
  end

  it "supports version and rule-filtered explain output" do
    version_status, version, = run_cli("--version")
    explain_status, explanation, = run_cli("explain", spec_path, "--rule", "0")

    expect(version_status).to eq(0)
    expect(version).to eq("#{Flexr::VERSION}\n")
    expect(explain_status).to eq(0)
    expect(explanation).to include("rule 0:")
  end

  it "renders warning diagnostics as one JSON document" do
    path = File.join(Dir.tmpdir, "flexr-warning-#{Process.pid}.flexr.rb")
    File.write(path, <<~RUBY)
      require "flexr"
      class WarningLexer < Flexr::Lexer
        rule(/a/, skip: true)
        rule(/a/, skip: true)
      end
    RUBY

    status, output, errors = run_cli("check", path, "--format", "json", "--warn", "all")
    expect(status).to eq(0)
    expect(JSON.parse(output).map { |item| item.fetch("code") }).to include("FLEXR-W001")
    expect(errors).to be_empty
  ensure
    FileUtils.rm_f(path)
  end

  it "reports undeclared emit tokens during check" do
    path = File.join(Dir.tmpdir, "flexr-undeclared-#{Process.pid}.flexr.rb")
    File.write(path, <<~RUBY)
      require "flexr"
      class UndeclaredLexer < Flexr::Lexer
        emits :A
        rule(/a/) { emit :B }
      end
    RUBY

    status, output, errors = run_cli("check", path, "--format", "json", "--warn", "all")
    expect(status).to eq(0)
    expect(JSON.parse(output).map { |item| item.fetch("code") }).to include("FLEXR-W014")
    expect(errors).to be_empty
  ensure
    FileUtils.rm_f(path)
  end

  it "includes actionable help for compiler warnings" do
    path = File.join(Dir.tmpdir, "flexr-warning-help-#{Process.pid}.flexr.rb")
    File.write(path, <<~RUBY)
      require "flexr"
      class WarningHelpLexer < Flexr::Lexer
        emits :DECLARED
        state :unused do
        end
        rule(/(a)/) { emit :UNDECLARED }
      end
    RUBY

    status, output, errors = run_cli("check", path, "--format", "json", "--warn", "all")
    diagnostics = JSON.parse(output)
    codes = diagnostics.to_h { |diagnostic| [diagnostic.fetch("code"), diagnostic] }

    expect(status).to eq(0)
    expect(codes.fetch("FLEXR-W002").fetch("help")).not_to be_empty
    expect(codes.fetch("FLEXR-W013").fetch("help")).not_to be_empty
    expect(codes.fetch("FLEXR-W014").fetch("help")).not_to be_empty
    expect(errors).to be_empty
  ensure
    FileUtils.rm_f(path) if path
  end
end
