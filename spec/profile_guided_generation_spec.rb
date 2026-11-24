# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "stringio"

RSpec.describe "profile-guided generation" do
  around do |example|
    Dir.mktmpdir("flexr-profile-") do |directory|
      @directory = directory
      example.run
    end
  end

  let(:source) do
    <<~'RUBY'
      require "flexr"
      class ProfileFixtureLexer < Flexr::Lexer
        token_kind :struct
        rule(/[a-z]+/, emit: :WORD)
        rule(/[ \n]+/, skip: true)
        rule("!", emit: :BANG)
        rule("é", emit: :ACCENT)
      end
    RUBY
  end
  let(:spec_path) { write_file("lexer.flexr.rb", source) }
  let(:output) { File.join(@directory, "lexer.rb") }

  def write_file(name, contents)
    path = File.join(@directory, name)
    File.binwrite(path, contents)
    path
  end

  def run_cli(*args)
    stdout = StringIO.new
    stderr = StringIO.new
    status = Flexr::CLI.run(args, out: stdout, err: stderr)
    [status, stderr.string]
  end

  def generate(*, lexer_spec: spec_path)
    status, error = run_cli("generate", lexer_spec, *, "-o", output)
    expect(status).to eq(0), error
    File.binread(output).force_encoding(Encoding::UTF_8)
  end

  def lexer_from(ruby_source)
    scope = Module.new
    scope.module_eval(ruby_source)
    scope.const_get(:ProfileFixtureLexer, false)
  end

  def metadata(artifact, label)
    line = artifact.lines.find { |entry| entry.start_with?("# #{label}: ") }
    expect(line).not_to be_nil
    JSON.parse(line.delete_prefix("# #{label}: "))
  end

  it "uses corpus-dependent strategies and preserves frozen and mutable token locations" do
    training = "#{'a' * 512}#{' ' * 512}!é\n" * 12
    long = write_file("long.txt", training)
    short = write_file("short.txt", "a !é\n" * 12)
    profiled = generate("--profile", long, "--backend", "direct", "--table-format", "packed")
    short_profile = generate("--profile", short, "--backend", "direct", "--table-format", "packed")

    expect(metadata(profiled, "profile-strategies")).not_to eq(metadata(short_profile, "profile-strategies"))
    expected = lexer_from(source)
    actual = lexer_from(profiled)
    native_scans = 0
    trace = TracePoint.new(:c_call) do |event|
      native_scans += 1 if event.method_id == :skip && event.self.is_a?(StringScanner)
    end
    actual_tokens = trace.enable { actual.new(training.dup.freeze).tokens }
    expect(actual_tokens).to eq(expected.new(training.dup.freeze).tokens)
    expect(native_scans).to be_positive

    [training, "a é!\n#{'b' * 96}!"].each do |input|
      [input.dup, input.dup.freeze].each do |value|
        options = {filename: "sample.txt", freeze_input: false}
        expect(actual.new(value, **options).tokens).to eq(expected.new(value, **options).tokens)
      end
    end
    [actual, expected].each do |lexer|
      expect { lexer.new(training.dup.freeze, max_token_size: 16).tokens }
        .to raise_error(Flexr::Runtime::TokenTooLargeError)
    end
  end

  it "reproduces bytes when globs overlap and keeps corpus paths and text out of the header" do
    first = write_file("first.txt", "a" * 40)
    second = write_file("second.txt", "secretsample" * 16)
    glob = File.join(@directory, "*.txt")
    first_output = generate("--profile", first, "--profile", glob, "--profile", second)
    second_output = generate("--profile", second, "--profile", first)

    expect(first_output).to eq(second_output)
    expect(metadata(first_output, "profile")).to include("files" => 2, "bytes" => 232, "tokens" => 2)
    header = first_output.lines.grep(/\A# profile/).join
    expect(header).not_to include(first, second, "secretsample")
  end

  it "keeps the DFA path for a frozen string in another encoding" do
    grammar = <<~RUBY
      class ProfileFixtureLexer < Flexr::Lexer
        encoding "ASCII-8BIT"
        rule(/a+/n, emit: :AS)
        rule(/./n, emit: :BYTE)
      end
    RUBY
    path = write_file("binary.flexr.rb", grammar)
    corpus = write_file("binary.txt", "#{'a' * 512}x" * 4)
    profiled = generate("--profile", corpus, lexer_spec: path)
    expect(metadata(profiled, "profile-strategies").fetch("whole_tokens").fetch("initial")).to include("a".ord)

    input = "aax".encode(Encoding::UTF_16LE).freeze
    expect(lexer_from(profiled).new(input).tokens).to eq(lexer_from(grammar).new(input).tokens)
  end

  [
    ['encoding "ASCII-8BIT"', 'rule(/[^\n]+/n, emit: :LINE)', "#{"\xffa".b * 256}\n".b * 4, :byteindex],
    [nil, 'rule(/a+b/, emit: :AB); rule(/a+/, emit: :A)', "#{'a' * 512}b\n" * 4, :skip]
  ].each do |encoding, rules, corpus_text, method|
    it "runs the profiled #{method} loop across direct and packed tables" do
      grammar = <<~RUBY
        class ProfileFixtureLexer < Flexr::Lexer
          #{encoding}
          token_kind :struct
          #{rules}
          rule("\\n", skip: true)
        end
      RUBY
      path = write_file("loop.flexr.rb", grammar)
      corpus = write_file("loop.txt", corpus_text)
      profiled = generate("--profile", corpus, "--backend", "direct", "--table-format", "packed", lexer_spec: path)
      expected = lexer_from(grammar)
      actual = lexer_from(profiled)
      input = corpus_text.dup.freeze
      calls = 0
      trace = TracePoint.new(:c_call) { |event| calls += 1 if event.method_id == method }
      expect(trace.enable { actual.new(input).tokens }).to eq(expected.new(input).tokens)
      expect(calls).to be_positive
    end
  end

  it "does not run top-level code or rule blocks when profiling" do
    path = write_file("opaque.flexr.rb", <<~RUBY)
      require "flexr"
      raise "top level was executed"
      class ProfileFixtureLexer < Flexr::Lexer
        rule(/[a-z]+/) { raise "rule was executed" }
      end
    RUBY
    corpus = write_file("opaque.txt", "abc")

    expect(generate("--profile", corpus, lexer_spec: path)).to include("# profile:")
  end

  it "executes the profiled standalone artifact without the Flexr gem" do
    value = "#{'a' * 512} !é"
    corpus = write_file("standalone.txt", "#{value}\n" * 12)
    generate("--profile", corpus, "--standalone")
    script = <<~'RUBY'
      load ARGV.fetch(0)
      actual = ProfileFixtureLexer.new(ARGV.fetch(1).freeze).tokens.map(&:type)
      abort "unexpected tokens: #{actual.inspect}" unless actual == %i[WORD BANG ACCENT]
    RUBY
    environment = {"RUBYOPT" => nil, "RUBYLIB" => nil}
    _stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, "--disable-gems", "-e", script, output, value)

    expect(status).to be_success, stderr
  end

  it "reports an unmatched glob without replacing an existing artifact" do
    contents = "existing artifact"
    write_file("lexer.rb", contents)
    status, error = run_cli("generate", spec_path, "--profile", File.join(@directory, "missing-*.txt"), "-o", output)

    expect(status).not_to eq(0)
    expect(error.lines.first).to match(/profile.*(no |match|regular file)/i)
    expect(File.binread(output)).to eq(contents)
  end

  it "rejects output paths that would overwrite a corpus file" do
    contents = "a" * 64
    corpus = write_file("training.txt", contents)
    status, error = run_cli("generate", spec_path, "--profile", corpus, "-o", corpus)

    expect(status).not_to eq(0)
    expect(error).to match(/distinct|same file|overwrite|collision/i)
    expect(File.binread(corpus)).to eq(contents)
  end

  [%w[--eval], %w[--backend firstmatch]].each do |flags|
    it "rejects a profile with #{flags.join(' ')}" do
      corpus = write_file("training.txt", "a" * 64)
      status, error = run_cli("generate", spec_path, "--profile", corpus, *flags, "-o", output)

      expect(status).not_to eq(0)
      expect(error.lines.first).to include("profile", flags.last)
      expect(File).not_to exist(output)
    end
  end
end
