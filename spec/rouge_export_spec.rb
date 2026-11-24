# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

RSpec.describe "Rouge export" do
  around do |example|
    Dir.mktmpdir("flexr-rouge-") do |directory|
      @directory = directory
      example.run
    end
  end

  def write_file(name, source)
    path = File.join(@directory, name)
    File.binwrite(path, source)
    path
  end

  def export(body, *options)
    @source = "raise 'the specification must not execute'\nmodule Paint\n  class Lexer < Flexr::Lexer\n#{body}\n  end\nend\n"
    path = write_file("paint.flexr.rb", @source)
    out = StringIO.new
    err = StringIO.new
    status = Flexr::CLI.run(["export", path, "--to", "rouge", *options], out: out, err: err)
    [status, out.string, err.string]
  end

  def highlights(output, input, scope: Module.new)
    require "rouge"

    scope.module_eval(output)
    klass = scope.const_get(:Paint, false).const_get(:LexerRougeLexer, false)
    expect(klass).to be < Rouge::RegexLexer
    klass.new.lex(input).map { |token, value| [token.qualname, value] }
  end

  it "exports deterministic namespaced states with mapped tokens, channels, and skipped text" do
    body = <<~SPEC
      rule(/[a-z]+/, emit: :IDENT)
      rule(/ +/, skip: true)
      rule("#", channel: :comment) { emit(:IDENT) }
      rule('"') { push :quoted; emit :DELIMITER }
      rule("(") { begin_state :quoted; emit :DELIMITER }
      state(:quoted, inclusive: false) do
        rule(/[a-z]+/, emit: :CONTENTS)
        rule('"') { pop; emit :DELIMITER }
      end
    SPEC
    mapping = write_file("tokens.json", JSON.generate(tokens: { IDENT: "Name.Variable", DELIMITER: "Punctuation", CONTENTS: "Literal.String" },
                                                     channels: { comment: "Comment.Single" }))
    status, output, errors = export(body, "--token-map", mapping)
    expect(status).to eq(0), errors
    expect(errors).to be_empty
    expect(output).to include("require \"rouge\"")
    expect(output).to match(/state\s*\(?\s*:root/)
    expect(export(body, "--token-map", mapping)).to eq([0, output, ""])

    expect(highlights(output, 'a # "b" (d" c')).to eq([
      ["Name.Variable", "a"], ["Text", " "], ["Comment.Single", "#"], ["Text", " "],
      ["Punctuation", '"'], ["Literal.String", "b"], ["Punctuation", '"'], ["Text", " "],
      ["Punctuation", "("], ["Literal.String", "d"], ["Punctuation", '"'], ["Text", " "], ["Name.Variable", "c"]
    ])
  end

  it "keeps native firstmatch ordering when Rouge would otherwise select a different token" do
    body = <<~SPEC
      backend :firstmatch
      rule(/a/, emit: :SHORT)
      rule(/ab/, emit: :LONG)
      rule(/b/, emit: :TAIL)
    SPEC
    mapping = write_file("tokens.json", JSON.generate(tokens: { SHORT: "Keyword", LONG: "Name", TAIL: "Punctuation" }))
    status, output, errors = export(body, "--token-map", mapping)
    expect(status).to eq(0), errors
    expect(highlights(output, "ab")).to eq([%w[Keyword a], %w[Punctuation b]])
  end

  it "reports the difference when a firstmatch pattern array chooses a longer alternative" do
    body = "backend :firstmatch\nrule([/a/, /ab/], emit: :IDENT)\n"
    status, output, errors = export(body)

    expect(status).not_to eq(0)
    expect(output).to be_empty
    expect(errors).to include('"ab"')
  end

  it "checks shortest-match states against Rouge's native ordering" do
    body = "state(:initial, inclusive: true, match: :shortest) { rule(/a/, emit: :IDENT) }"
    status, output, errors = export(body)
    expect(status).to eq(0), errors
    expect(highlights(output, "aa")).to eq([%w[Name aa]])

    status, output, errors = export(body.sub("/a/", "/a+/"))
    expect(status).not_to eq(0)
    expect(output).to be_empty
    expect(errors).to include('"aa"')
  end

  it "adds the highlighter to an existing class namespace" do
    status, output, errors = export('rule("!", emit: :OPERATOR)')
    expect(status).to eq(0), errors
    scope = Module.new
    scope.const_set(:Paint, Class.new)

    expect(highlights(output, "!", scope: scope)).to eq([%w[Operator !]])
  end

  it "reports an overridden emission hook before exporting" do
    body = <<~SPEC
      def emit(type, value = text)
        super(:COMMENT, value)
      end
      rule("a", emit: :IDENT)
    SPEC
    status, output, errors = export(body, "--format", "json")

    expect(status).not_to eq(0)
    expect(output).to be_empty
    diagnostic = JSON.parse(errors).first
    expect(diagnostic.fetch("message")).to include("emit")
    first, last = diagnostic.fetch("location")
    expect(@source.byteslice(first...last)).to include("emit")
  end

  it "reports the shortest rule-selection witness and preserves an existing output on failure" do
    body = <<~SPEC
      rule(/a/, emit: :SHORT)
      rule(/ab/, emit: :LONG)
      rule(/b/, emit: :TAIL)
    SPEC
    path = write_file("highlight.rb", "existing\n")
    status, output, errors = export(body, "-o", path)

    expect(status).not_to eq(0)
    expect(output).to be_empty
    expect(errors).to match(/witness|differ|counterexample/i)
    expect(errors).to include('"ab"')
    expect(errors).to match(/paint\.flexr\.rb:[45]:\d+/)
    expect(File.binread(path)).to eq("existing\n")
  end

  {
    'rule(pattern(/a/) | pattern(/b/), emit: :CHOICE)' => [/pattern/i, "pattern(/a/) | pattern(/b/)"],
    'rule(/(?<=x)a/, emit: :AFTER_X)' => [/lookbehind|lookaround|context/i, "(?<=x)"],
    'rule(/a/) { emit(dynamic_token) }' => [/action|opaque/i, "emit(dynamic_token)"]
  }.each do |body, (reason, unsupported)|
    it "locates unsupported source in #{body}" do
      status, output, errors = export(body, "--format", "json")

      expect(status).not_to eq(0)
      expect(output).to be_empty
      diagnostic = JSON.parse(errors).first
      expect(diagnostic.fetch("message")).to match(reason)
      first, last = diagnostic.fetch("location")
      offset = @source.b.index(unsupported)
      expect(first).to be < offset + unsupported.bytesize
      expect(last).to be > offset
    end
  end

  it "rejects a mapping whose token entries are not an object" do
    mapping = write_file("tokens.json", '{"tokens":["Name.Variable"]}')
    status, output, errors = export('rule("!", emit: :OPERATOR)', "--token-map", mapping)

    expect(status).not_to eq(0)
    expect(output).to be_empty
    expect(errors.lines.first).to match(/tokens.*(object|mapping|hash)/i)
  end

  it "writes a verified artifact to the requested output" do
    path = File.join(@directory, "highlight.rb")
    body = 'rule("!", emit: :OPERATOR)'
    status, output, errors = export(body, "-o", path)

    expect(status).to eq(0), errors
    expect(output).to be_empty
    expect(File.binread(path)).to include("LexerRougeLexer")
  end
end
