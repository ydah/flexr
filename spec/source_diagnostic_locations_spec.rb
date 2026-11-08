# frozen_string_literal: true

require "stringio"

RSpec.describe "source diagnostic locations" do
  around do |example|
    Dir.mktmpdir("flexr-source-locations") do |directory|
      @path = File.join(directory, "lexer.flexr.rb")
      example.run
    end
  end

  def write_spec(body)
    @source = "# UTF-8: é\nclass SourceLocationFixture < Flexr::Lexer\n#{body}\nend\n"
    File.binwrite(@path, @source)
  end

  def span(fragment)
    offset = @source.b.index(fragment.b)
    [offset, offset + fragment.bytesize]
  end

  def expect_location(code, fragment)
    output = StringIO.new
    errors = StringIO.new
    status = Flexr::CLI.run(["check", @path, "--format", "json"], out: output, err: errors)

    expect(status).to eq(1)
    expect(output.string).to be_empty
    expect(JSON.parse(errors.string).first).to include("code" => code, "location" => span(fragment))

    error_class = code == "FLEXR-E017" ? Flexr::StaticResolutionError : Flexr::CompileError
    expect { Flexr::Generator.new(@path).generate }.to raise_error(error_class) do |error|
      expect(error.diagnostic.code).to eq(code)
      expect(error.diagnostic.location).to eq(span(fragment))
    end
  end

  {
    "unsupported encoding" => ["FLEXR-E011", 'encoding "US-ASCII"'],
    "reject action" => ["FLEXR-E013", "rule(/a/) { reject }"],
    "invalid pattern type" => ["FLEXR-E018", "rule(123, skip: true)"],
    "invalid trailing context type" => ["FLEXR-E018", "rule(/a/, followed_by: 123, skip: true)"],
    "unknown rule keyword" => ["FLEXR-E017", "rule(/a/, typo: true)"],
    "receiver-qualified DSL call" => ["FLEXR-E017", "self.rule(/a/, skip: true)"],
    "dynamic DSL dispatch" => ["FLEXR-E017", "send(:rule, /a/, skip: true)"],
    "all_states arguments" => ["FLEXR-E017", "all_states(:word) { rule(/a/, skip: true) }"],
    "unknown state keyword" => ["FLEXR-E017", "state(:word, typo: true) { rule(/a/, skip: true) }"]
  }.each do |name, (code, statement)|
    it "locates the #{name} in check and generation" do
      write_spec("  #{statement}")

      expect_location(code, statement)
    end
  end

  %w[Time.now MISSING].each do |expression|
    it "locates the unresolved expression #{expression} rather than the enclosing rule" do
      write_spec("  rule(#{expression}, skip: true)")

      expect_location("FLEXR-E017", expression)
    end
  end

  it "locates the DSL call hidden inside control flow" do
    statement = "rule(/a/, skip: true)"
    write_spec("  if true\n    #{statement}\n  end")

    expect_location("FLEXR-E017", statement)
  end

  it "keeps a nested rule's location when the error propagates through state blocks" do
    statement = "rule(123, skip: true)"
    write_spec("  state :outer do\n    state :inner do\n      #{statement}\n    end\n  end")

    expect_location("FLEXR-E018", statement)
  end

  it "locates the second lexer class when the source is ambiguous" do
    write_spec("  rule(/a/, skip: true)")
    other = "class OtherLexer < Flexr::Lexer\n  rule(/b/, skip: true)\nend"
    @source << "#{other}\n"
    File.binwrite(@path, @source)

    expect_location("FLEXR-E017", other)
  end

  it "renders the unresolved expression with a caret range through the CLI" do
    write_spec("  rule(Time.now, skip: true)")
    output = StringIO.new
    errors = StringIO.new

    status = Flexr::CLI.run(["check", @path, "--color", "never"], out: output, err: errors)

    expect(status).to eq(1)
    expect(output.string).to be_empty
    expect(errors.string).to include("error[FLEXR-E017]", "  --> #{@path}:3:8\n",
                                    "3 |   rule(Time.now, skip: true)\n", "  |        ^^^^^^^^\n")
  end

  it "continues to defer unresolved expressions when dynamic patterns are allowed" do
    write_spec("  rule(MISSING, skip: true)")

    parsed = Flexr::Source::PrismReader.new(@source, path: @path).read(allow_dynamic: true)

    expect(parsed.rules.first.patterns).to eq([nil])
  end
end
