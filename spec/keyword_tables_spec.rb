# frozen_string_literal: true

require "open3"
require "stringio"

RSpec.describe "keyword tables" do
  let(:source) do
    <<~'RUBY'
      require "flexr"
      class KeywordLexer < Flexr::Lexer
        rule(/\s+/, skip: true)
        rule(/[[:alpha:]_][[:alnum:]_]*/, emit: :IDENT)
        keywords %w[if else élève], among: :IDENT
        keywords({ "yes" => :TRUE, "true" => :TRUE }, among: :IDENT)
        rule("::", emit: :SCOPE)
        emits :SCOPE
      end
    RUBY
  end

  def with_spec(code = source)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(path, code)
      yield path, directory
    end
  end

  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    [Flexr::CLI.run(argv, out: out, err: err), out.string, err.string]
  end

  it "remaps exact accepted lexemes and preserves their values across execution modes" do
    input = "if ifx else élève :: yes true"
    expected = [[:IF, "if"], [:IDENT, "ifx"], [:ELSE, "else"], [:ÉLÈVE, "élève"], [:SCOPE, "::"],
                [:TRUE, "yes"], [:TRUE, "true"]]

    with_spec do |path, directory|
      scope = Module.new
      scope.module_eval(source, path)
      expect(scope::KeywordLexer.new(StringIO.new(input), chunk_size: 1).tokens).to(
        eq(expected.map { |type, value| [type, value.b] })
      )
      generated = Module.new
      generated.module_eval(Flexr::Generator.new(path).generate, path)
      expect(generated::KeywordLexer.new(input).tokens).to eq(expected)

      standalone = File.join(directory, "standalone.rb")
      File.binwrite(standalone, Flexr::Generator.new(path, options: { standalone: true }).generate)
      runner = File.join(directory, "run.rb")
      File.binwrite(runner, "require_relative 'standalone'\nputs JSON.generate(KeywordLexer.new(ARGV.fetch(0)).tokens)\n")
      out, err, result = Open3.capture3(RbConfig.ruby, "--disable-gems", runner, input)
      expect(result).to be_success, err
      expect(JSON.parse(out)).to eq(expected.map { |type, value| [type.to_s, value] })
    end
  end

  it "uses only the winning rule's lexeme during more and leaves the emitted value intact" do
    code = <<~RUBY
      class KeywordLexer < Flexr::Lexer
        token_kind :struct
        rule(":") { more }
        rule(/[a-z]+/, emit: :IDENT)
        keywords %w[if], among: :IDENT
      end
    RUBY
    with_spec(code) do |path, _directory|
      [code, Flexr::Generator.new(path).generate].each do |ruby|
        scope = Module.new
        scope.module_eval(ruby, path)
        token = scope::KeywordLexer.new(":if").next_token
        expect([token.type, token.value]).to eq([:IF, ":if"])
        expect(token.location.byte_end).to eq(3)
      end
    end
  end

  it "shows keyword mappings in DOT and explain and the mapped token in input trace" do
    with_spec do |path, _directory|
      %w[dot explain trace].each do |command|
        status, out, err = run_cli(command, path)
        expect(status).to eq(0), err
        expect(out).to include("keywords among :IDENT", "=> :IF")
      end
      [[], ["--generated"]].each do |options|
        status, out, err = run_cli("trace", path, "--input", "if", "--format", "json", *options)
        expect(status).to eq(0), err
        expect(JSON.parse(out).fetch("steps").first.fetch("token")).to eq('[:IF, "if"]')
      end
    end
  end

  it "keeps keywords out of the DFA and preserves custom actions and competing rules" do
    lexer = Class.new(Flexr::Lexer) do
      rule("else", emit: :SPECIAL)
      rule("custom") { emit :IDENT, :custom_value }
      rule(/[a-z]+/, emit: :IDENT)
      keywords %w[if else custom], among: :IDENT
      rule(/\s+/, skip: true)
    end
    expect(lexer.new("if else custom ifx").tokens).to eq(
      [[:IF, "if"], [:SPECIAL, "else"], %i[IDENT custom_value], [:IDENT, "ifx"]]
    )

    plain = Class.new(Flexr::Lexer) { rule(/[a-z]+/, emit: :IDENT) }
    classified = Class.new(Flexr::Lexer) do
      rule(/[a-z]+/, emit: :IDENT)
      keywords %w[if else], among: :IDENT
    end
    expect(classified.compile!.stats).to eq(plain.compile!.stats)
  end

  it "does not inherit keyword remapping when a subclass declares its own rules" do
    parent = Class.new(Flexr::Lexer) do
      rule(/[a-z]+/, emit: :IDENT)
      keywords %w[if], among: :IDENT
    end
    expect(parent.new("if").tokens).to eq([[:IF, "if"]])
    child = Class.new(parent) { rule(/[a-z]+/, emit: :IDENT) }
    expect(child.new("if").tokens).to eq([[:IDENT, "if"]])
  end

  it "uses the evaluated keyword table when generation explicitly enables eval" do
    code = <<~RUBY
      class KeywordEvalLexer < Flexr::Lexer
        WORDS = %w[if else]
        rule(/[a-z]+/, emit: :IDENT)
        keywords WORDS.reverse, among: :IDENT
      end
    RUBY
    with_spec(code) do |path, _directory|
      expect { Flexr::Generator.new(path).generate }.to raise_error(Flexr::StaticResolutionError)
      scope = Module.new
      scope.module_eval(Flexr::Generator.new(path, eval_mode: true).generate, path)
      expect(scope::KeywordEvalLexer.new("if").tokens).to eq([[:IF, "if"]])
    ensure
      Object.send(:remove_const, :KeywordEvalLexer) if Object.const_defined?(:KeywordEvalLexer, false)
    end
  end

  it "declares the base and mapped types once for tokens and grammar validation" do
    with_spec(source.sub(" élève", "")) do |path, directory|
      grammar = File.join(directory, "parser.y")
      File.binwrite(grammar, "%token IDENT IF ELSE TRUE SCOPE\n%%\n")
      status, out, err = run_cli("tokens", path, "--format", "lrama")
      expect(status).to eq(0), err
      expect(out).to eq("%token IDENT IF ELSE TRUE SCOPE\n")
      status, out, err = run_cli("check", path, "--grammar", grammar, "--format", "json")
      expect(status).to eq(0), err
      expect(JSON.parse(out)).to be_empty
    end
  end

  it "rejects a keyword that only partially matches the target rule and reports its declaration" do
    code = <<~RUBY
      class KeywordLexer < Flexr::Lexer
        rule(/[a-z]+/, emit: :IDENT)
        keywords %w[if!], among: :IDENT
      end
    RUBY
    with_spec(code) do |path, _directory|
      status, _out, err = run_cli("check", path, "--format", "json")
      expect(status).to eq(1)
      diagnostic = JSON.parse(err).fetch(0)
      expect(diagnostic.fetch("code")).to eq("FLEXR-E028")
      expect(diagnostic.fetch("note")).to include("if!")
      expect(code.byteslice(diagnostic.fetch("location").first, 8)).to eq("keywords")
    end
  end

  it "rejects a different type for an existing spelling and accepts aliases of one type" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/[a-z]+/, emit: :IDENT)
      keywords({ "true" => :YES, "yes" => :YES }, among: :IDENT)
    end
    expect { lexer.keywords(%w[true], among: :IDENT) }.to raise_error(Flexr::CompileError, /true/)
    expect(lexer.new("yes").tokens).to eq([[:YES, "yes"]])
  end

  it "reports a keyword covered by an earlier literal rule" do
    code = <<~RUBY
      class KeywordLexer < Flexr::Lexer
        rule("if", emit: :SPECIAL)
        rule(/[a-z]+/, emit: :IDENT)
        keywords %w[if], among: :IDENT
        emits :SPECIAL
      end
    RUBY
    with_spec(code) do |path, _directory|
      status, out, err = run_cli("check", path, "--format", "json")
      expect(status).to eq(0), err
      expect(JSON.parse(out)).to include(hash_including("code" => "FLEXR-W022", "note" => /"if"/))
    end
  end

  it "suggests grouping consecutive literal rules covered by the same identifier" do
    code = <<~RUBY
      class KeywordLexer < Flexr::Lexer
        rule("if", emit: :IF)
        rule("else", emit: :ELSE)
        rule(/[a-z]+/, emit: :IDENT)
      end
    RUBY
    with_spec(code) do |path, _directory|
      status, out, err = run_cli("check", path, "--format", "json", "--warn-as-error")
      expect(status).to eq(0), err
      expect(JSON.parse(out)).to include(hash_including("code" => "FLEXR-I003", "help" => /keywords.*IDENT/))
      _status, silenced, _err = run_cli("check", path, "--format", "json", "--warn", "none")
      expect(JSON.parse(silenced)).not_to include(hash_including("code" => "FLEXR-I003"))
    end
    with_spec(code.sub("rule(/[a-z]+/", "rule(/other/, emit: :OTHER)\n  rule(/[a-z]+/")) do |path, _directory|
      _status, out, _err = run_cli("check", path, "--format", "json")
      expect(JSON.parse(out)).not_to include(hash_including("code" => "FLEXR-I003"))
    end
    with_spec(code.sub("rule(/[a-z]+/, emit: :IDENT)", "rule(/[a-z]+/, emit: :IDENT)\n  keywords({ 'if' => :SPECIAL }, among: :IF)")) do |path, _directory|
      _status, out, _err = run_cli("check", path, "--format", "json")
      expect(JSON.parse(out)).not_to include(hash_including("code" => "FLEXR-I003"))
    end
  end
end
