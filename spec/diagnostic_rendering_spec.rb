# frozen_string_literal: true

require "stringio"

RSpec.describe Flexr::DiagnosticSet do
  let(:source) { "class Lexer < Flexr::Lexer\n  rule(/if/) { emit :IF }\nend\n" }
  let(:location) { [source.index("rule"), source.index("\nend")] }
  let(:diagnostic) do
    Flexr::Diagnostics.warning("FLEXR-W001", "rule is unreachable", location: location,
                               help: "reorder the rules", note: "an earlier rule wins")
  end
  let(:set) { described_class.new << diagnostic }

  it "renders source coordinates and a caret range before help and notes" do
    expect(set.render(color: :never, source: source, path: "lexer.flexr.rb")).to eq(<<~TEXT.chomp)
      warning[FLEXR-W001]: rule is unreachable
        --> lexer.flexr.rb:2:3
        |
      2 |   rule(/if/) { emit :IF }
        |   ^^^^^^^^^^^^^^^^^^^^^^^
        help: reorder the rules
        note: an earlier rule wins
    TEXT
  end

  it "keeps rendering without source context backward compatible" do
    expect(set.render(color: :never)).to eq(<<~TEXT.chomp)
      warning[FLEXR-W001]: rule is unreachable
        help: reorder the rules
        note: an earlier rule wins
    TEXT
  end

  it "keeps JSON locations as byte ranges without embedding source context" do
    expect(JSON.parse(set.render(format: :json, source: source, path: "lexer.flexr.rb")))
      .to eq([JSON.parse(JSON.generate(diagnostic.to_h))])
  end

  it "counts UTF-8 characters rather than bytes and preserves indentation tabs" do
    text = "# é\n\té = 1; rule(/é/)\n"
    offset = text.b.index("rule")
    diagnostic.location = [offset, text.bytesize - 1]

    expect(set.render(color: :never, source: text, path: "utf8.flexr.rb")).to include(
      "  --> utf8.flexr.rb:2:9\n",
      "2 | \té = 1; rule(/é/)\n",
      "  | \t       ^^^^^^^^^"
    )
  end

  it "shows only the first source line of a multiline range and strips CRLF" do
    text = "#{"\r\n" * 9}  rule(/if/) do\r\n    emit :IF\r\n  end\r\n"
    diagnostic.location = [text.index("rule"), text.bytesize]

    rendered = set.render(color: :never, source: text, path: "multiline.flexr.rb")

    expect(rendered).to include(<<~TEXT.chomp)
        --> multiline.flexr.rb:10:3
         |
      10 |   rule(/if/) do
         |   ^^^^^^^^^^^^^
    TEXT
    expect(rendered).not_to include("\r", "emit :IF", "  end")
  end

  it "marks an empty range at the end of the source with one caret" do
    diagnostic.location = [source.bytesize, source.bytesize]

    expect(set.render(color: :never, source: source)).to include("  --> (source):4:1\n  |\n4 | \n  | ^")
  end

  it "omits source context for missing or invalid byte ranges" do
    [nil, [], [-1, 2], [3, 2], [source.bytesize + 1, source.bytesize + 2], %w[1 2]].each do |range|
      diagnostic.location = range

      expect(set.render(color: :never, source: source, path: "lexer.flexr.rb"))
        .to eq(set.render(color: :never))
    end
  end

  it "can render a syntax error in source containing invalid UTF-8" do
    text = "# \xff\nrule(/\xff/)".b.force_encoding(Encoding::UTF_8)
    diagnostic.location = [text.b.index("rule"), text.bytesize]

    expect(set.render(color: :never, source: text)).to include("  --> (source):2:1\n", "2 | rule(/\uFFFD/)")
  end
end

RSpec.describe "CLI diagnostic source context" do
  let(:source) do
    <<~RUBY
      class DiagnosticSourceFixture < Flexr::Lexer
        rule(/[a-z]+/, skip: true)
        rule(/if/, skip: true)
      end
    RUBY
  end

  around do |example|
    Dir.mktmpdir("flexr-diagnostic-source") do |directory|
      @path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(@path, source)
      example.run
    end
  end

  def run_cli(*arguments)
    output = StringIO.new
    errors = StringIO.new
    status = Flexr::CLI.run(arguments, out: output, err: errors)
    [status, output.string, errors.string]
  end

  it "shows source context for check warnings" do
    status, output, errors = run_cli("check", @path, "--color", "never")

    expect(status).to eq(0)
    expect(errors).to be_empty
    expect(output).to eq(<<~TEXT)
      warning[FLEXR-W001]: rule /if/ is unreachable (shadowed by rule /[a-z]+/)
        --> #{@path}:3:3
        |
      3 |   rule(/if/, skip: true)
        |   ^^^^^^^^^^^^^^^^^^^^^^
        help: remove it, reorder the rules, or make its language distinct
    TEXT
  end

  it "uses normalized source offsets for generation failures on CRLF files" do
    File.binwrite(@path, source.gsub("\n", "\r\n"))

    status, output, errors = run_cli(@path, "--warn-as-error", "--color", "never")

    expect(status).to eq(1)
    expect(output).to be_empty
    expect(errors).to include("  --> #{@path}:3:3\n", "3 |   rule(/if/, skip: true)\n",
                              "  |   ^^^^^^^^^^^^^^^^^^^^^^\n")
  end

  it "keeps original CRLF byte ranges in check JSON and uses them for human output" do
    text = source.gsub("\n", "\r\n")
    File.binwrite(@path, text)

    status, output, errors = run_cli("check", @path, "--format", "json")

    expect(status).to eq(0)
    expect(errors).to be_empty
    expect(JSON.parse(output).first.fetch("location"))
      .to eq([text.index("rule(/if/"), text.index("\r\nend")])
    expect(run_cli("check", @path, "--color", "never")[1])
      .to include("  --> #{@path}:3:3\n", "3 |   rule(/if/, skip: true)\n")
  end

  it "shows the same source context when checking with eval" do
    File.binwrite(@path, source.gsub("\n", "\r\n"))

    status, output, errors = run_cli("check", @path, "--eval", "--color", "never")

    expect(status).to eq(0)
    expect(errors).to be_empty
    expect(output).to include("  --> #{@path}:3:3\n", "3 |   rule(/if/, skip: true)\n")
  ensure
    Object.send(:remove_const, :DiagnosticSourceFixture) if Object.const_defined?(:DiagnosticSourceFixture)
  end

  it "shows a source location for Prism syntax errors" do
    File.binwrite(@path, "class Lexer < Flexr::Lexer\n  rule(/a/) { emit :A }\n")

    status, output, errors = run_cli("check", @path, "--color", "never")

    expect(status).to eq(1)
    expect(output).to be_empty
    expect(errors).to include("error[FLEXR-E010]", "  --> #{@path}:", " |", "^")
  end

  it "uses original source offsets for commands that do not evaluate the spec" do
    File.binwrite(@path, "class Lexer < Flexr::Lexer\r\n  )\r\nend\r\n")

    status, output, errors = run_cli("stats", @path, "--eval", "--color", "never")

    expect(status).to eq(1)
    expect(output).to be_empty
    expect(errors).to include("  --> #{@path}:2:3\n", "2 |   )\n", "  |   ^")
  end

  it "preserves the diagnostic if its source file is no longer readable" do
    FileUtils.rm_f(@path)
    diagnostic = Flexr::Diagnostics.error("FLEXR-E010", "invalid source", location: [0, 1])
    error = Flexr::CompileError.new(diagnostic.message, diagnostic: diagnostic)

    expect(Flexr::CLI.render_error(error, path: @path)).to eq("error[FLEXR-E010]: invalid source")
  end
end
