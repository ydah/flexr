# frozen_string_literal: true

require "open3"
require "rbconfig"
require "stringio"

RSpec.describe "equal-length overlap diagnostics" do
  let(:source) do
    <<~RUBY
      require "flexr"
      class OverlapLexer < Flexr::Lexer
        rule(%w[a c], emit: :FIRST)
        rule(%w[b c], emit: :SECOND)
      end
    RUBY
  end

  around do |example|
    Dir.mktmpdir("flexr-overlap-") do |directory|
      @path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(@path, source)
      example.run
    end
  end

  def check(*options)
    output = StringIO.new
    errors = StringIO.new
    status = Flexr::CLI.run(["check", @path, *options], out: output, err: errors)
    expect(errors.string).to be_empty
    [status, output.string]
  end

  def infos(*options)
    _status, output = check("--warn", "all", "--format", "json", *options)
    JSON.parse(output).select { |item| item.fetch("code") == "FLEXR-I001" }
  end

  %w[table direct auto].each do |backend|
    it "reports a tie between reachable rules for #{backend}" do
      diagnostics = infos("--backend", backend)
      expect(diagnostics.length).to eq(1)
      expect(diagnostics.first).to include(
        "severity" => "info",
        "message" => 'rule ["b", "c"] overlaps rule ["a", "c"] at the same length',
        "note" => 'example: "c" selects rule ["a", "c"] (1 byte, earlier rule wins)'
      )
      start, finish = diagnostics.first.fetch("location")
      expect(source.byteslice(start...finish)).to eq('rule(%w[b c], emit: :SECOND)')
    end
  end

  it "does not report overlaps at default or none warning levels" do
    [[], ["--warn", "default"], ["--warn", "none"]].each do |options|
      status, output = check("--format", "json", *options)
      expect(status).to eq(0)
      expect(JSON.parse(output)).to be_empty
    end
  end

  it "does not fail warn-as-error for information alone" do
    status, output = check("--warn", "all", "--warn-as-error", "--format", "json")
    expect(status).to eq(0)
    expect(JSON.parse(output).map { |item| item.fetch("severity") }).to eq(["info"])
  end

  it "still fails warn-as-error for an unreachable-rule warning" do
    File.binwrite(@path, source.sub("%w[b c]", "%w[a c]"))
    status, output = check("--warn", "all", "--warn-as-error", "--format", "json")
    expect(status).to eq(1)
    expect(JSON.parse(output).map { |item| item.fetch("code") }).to include("FLEXR-W001", "FLEXR-I001")
  end

  it "renders source context and the input example for humans" do
    status, output = check("--warn", "all", "--color", "never")
    expect(status).to eq(0)
    expect(output).to include(
      'info[FLEXR-I001]: rule ["b", "c"] overlaps rule ["a", "c"] at the same length',
      "--> #{@path}:4:3", "4 |   rule(%w[b c], emit: :SECOND)",
      'note: example: "c" selects rule ["a", "c"] (1 byte, earlier rule wins)'
    )
  end

  it "reports one shortest example per later rule even when many inputs overlap" do
    File.binwrite(@path, source.sub("%w[a c]", "/[a-z]+/").sub("%w[b c]", "/[a-z]{6,8}/"))
    expect(infos.map { |item| item.fetch("note") }).to eq([
      'example: "aaaaaa" selects rule /[a-z]+/ (6 bytes, earlier rule wins)'
    ])
  end

  it "does not count two alternatives of the same rule as an overlap" do
    File.binwrite(@path, source.sub("%w[a c]", "%w[a a]").sub("%w[b c]", '"b"'))
    expect(infos).to be_empty
  end

  it "does not count prefix matches of different lengths as an overlap" do
    File.binwrite(@path, source.sub("%w[a c]", '"a"').sub("%w[b c]", '"ab"'))
    expect(infos).to be_empty
  end

  it "keeps Unicode examples readable and measures their byte length" do
    File.binwrite(@path, source.sub("%w[a c]", "/[aé]/").sub("%w[b c]", "/[bé]/"))
    expect(infos.first.fetch("note")).to eq('example: "é" selects rule /[aé]/ (2 bytes, earlier rule wins)')
  end

  it "escapes binary examples in JSON" do
    File.binwrite(@path, source.sub("  rule", "  encoding Encoding::BINARY\n  rule")
      .sub("%w[a c]", '/\xFF/n').sub("%w[b c]", '/\xFF/n'))
    expect(infos.first.fetch("note")).to include('example: "\xFF"', "1 byte, earlier rule wins")
  end

  it "omits invalid UTF-8 examples" do
    File.binwrite(@path, source.sub("%w[a c]", '/\xFF/n').sub("%w[b c]", '/\xFF/n'))
    expect(infos).to be_empty
  end

  it "omits examples that need an empty input" do
    File.binwrite(@path, source.sub("  rule", "  option :allow_empty_match\n  rule")
      .sub("%w[a c]", "//").sub("%w[b c]", "//"))
    expect(infos).to be_empty
  end

  it "names the lexical state and does not compare separate states" do
    File.binwrite(@path, <<~RUBY)
      class OverlapLexer < Flexr::Lexer
        rule(/c/, emit: :INITIAL)
        state :word do
          rule(%w[a c], emit: :FIRST)
          rule(%w[b c], emit: :SECOND)
        end
      end
    RUBY
    expect(infos.map { |item| item.fetch("note") }).to eq([
      'example: "c" selects rule ["a", "c"] in state :word (1 byte, earlier rule wins)'
    ])
  end

  it "does not report an unchecked trailing-context tie" do
    File.binwrite(@path, source.sub("emit: :FIRST", 'followed_by: "d", emit: :FIRST'))
    expect(infos).to be_empty
  end

  it "preserves information in generated and standalone artifacts without making it a warning" do
    output = File.join(File.dirname(@path), "lexer.rb")
    [false, true].each do |standalone|
      generator = Flexr::Generator.new(@path, output: output,
                                      options: { warn_level: :all, warn_as_error: true, standalone: standalone })
      generator.generate
      diagnostic = generator.diagnostics.find { |item| item.code == "FLEXR-I001" }
      expect(diagnostic).not_to be_nil
      expect(diagnostic.warning?).to be(false)
      script = <<~RUBY
        require "json"
        load ARGV.fetch(0)
        info = OverlapLexer.__flexr_compiled.diagnostics.find { |item| item.code == "FLEXR-I001" }
        puts JSON.generate([info.to_h, OverlapLexer.new("abc").tokens])
      RUBY
      result, errors, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script, output)
      expect(status).to be_success, errors
      expect(JSON.parse(result)).to eq([
        JSON.parse(JSON.generate(diagnostic.to_h)), [%w[FIRST a], %w[SECOND b], %w[FIRST c]]
      ])
    end
    expect(Flexr::Generator.new(@path).tap(&:generate).diagnostics.map(&:code)).not_to include("FLEXR-I001")
  end

  it "reports the same overlap with explicit evaluation" do
    expect(infos("--eval")).to eq(infos)
  ensure
    Object.send(:remove_const, :OverlapLexer) if Object.const_defined?(:OverlapLexer, false)
  end
end
