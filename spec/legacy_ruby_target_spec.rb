# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "stringio"

RSpec.describe "legacy Ruby targets" do
  around do |example|
    Dir.mktmpdir("flexr-legacy-ruby-") do |directory|
      @directory = directory
      example.run
    end
  end

  let(:source) do
    <<~'RUBY'
      require "flexr"
      class LegacyTargetLexer < Flexr::Lexer
        token_kind :struct
        rule(/[ \n]+/, skip: true)
        rule(/[éλ]+/, emit: :WORD)
        rule("!", emit: :BANG)
      end
    RUBY
  end
  let(:output) { File.join(@directory, "lexer.rb") }

  def run_generate(spec, *flags)
    path = File.join(@directory, "lexer.flexr.rb")
    File.binwrite(path, spec)
    errors = StringIO.new
    status = Flexr::CLI.run(["generate", path, *flags, "-o", output], out: StringIO.new, err: errors)
    [status, errors.string]
  end

  %w[2.5 3.0].each do |target|
    it "generates a standalone artifact with structured token parity for Ruby #{target}" do
      status, error = run_generate(source, "--standalone", "--target-ruby", target)
      expect(status).to eq(0), error

      content = "éλ\n !é"
      input = File.join(@directory, "input.txt")
      File.binwrite(input, content)
      lexer = Module.new.tap { |scope| scope.module_eval(source) }.const_get(:LegacyTargetLexer)
      expected = lexer.new(content, filename: "input.txt").tokens.map { |token| [token.type, token.value, token.location.to_h] }
      script = <<~RUBY
        require "json"
        load ARGV.fetch(0)
        text = File.binread(ARGV.fetch(1)).force_encoding(Encoding::UTF_8)
        tokens = LegacyTargetLexer.new(text, filename: "input.txt").tokens
        puts JSON.generate(tokens.map { |token| [token.type, token.value, token.location.to_h] })
      RUBY
      environment = {"RUBYOPT" => nil, "RUBYLIB" => nil}
      stdout, stderr, child_status = Open3.capture3(environment, RbConfig.ruby, "--disable-gems", "-e", script, output, input)

      expect(child_status).to be_success, stderr
      expect(JSON.parse(stdout)).to eq(JSON.parse(JSON.generate(expected)))
    end
  end

  [
    [%w[--target-ruby 2.5], /standalone/],
    [%w[--standalone --eval --target-ruby 3.0], /static|eval/],
    [%w[--standalone --target-ruby 2.4], /2\.4/]
  ].each do |flags, message|
    it "rejects #{flags.join(' ')} without replacing the output" do
      File.binwrite(output, "existing output")
      status, error = run_generate(source, *flags)

      expect(status).not_to eq(0)
      expect(error.lines.first).to match(message)
      expect(File.binread(output)).to eq("existing output")
    end
  end

  it "points to the source range of syntax introduced after the target Ruby" do
    spec = "#{source}\ndef forward(&)\n  listen(&)\nend\n"
    status, error = run_generate(spec, "--standalone", "--target-ruby", "3.0", "--format", "json")

    expect(status).not_to eq(0)
    expect(error).to start_with("[")
    diagnostic = JSON.parse(error).find { |item| item.fetch("severity") == "error" }
    first, last = diagnostic.fetch("location")
    expect(spec.byteslice(first...last)).to include("&")
    expect(File).not_to exist(output)
  end

  it "points to Ractor-specific code in a legacy standalone specification" do
    spec = "#{source}\nFlexr::Generated.shareable!(LegacyTargetLexer)\n"
    status, error = run_generate(spec, "--standalone", "--target-ruby", "2.5", "--format", "json")

    expect(status).not_to eq(0)
    expect(error).to start_with("[")
    diagnostic = JSON.parse(error).find { |item| item.fetch("severity") == "error" }
    first, last = diagnostic.fetch("location")
    expect(spec.byteslice(first...last)).to include("shareable!")
    expect(File).not_to exist(output)
  end

  it "replays named captures with the legacy MatchData API" do
    spec = <<~RUBY
      class LegacyTargetLexer < Flexr::Lexer
        rule(/é(?<letter>λ)/) do
          emit :LETTER, [captures.fetch(:letter), capture_data.byteoffset(:letter)]
        end
      end
    RUBY
    status, error = run_generate(spec, "--standalone", "--target-ruby", "2.5")
    expect(status).to eq(0), error

    script = <<~RUBY
      class MatchData
        alias_method :named_captures_with_keywords, :named_captures
        undef_method :byteoffset

        def named_captures
          named_captures_with_keywords
        end
      end

      load ARGV.fetch(0)
      tokens = LegacyTargetLexer.new("éλ", cancellation: -> { false }).tokens
      puts JSON.generate(tokens)
    RUBY
    environment = {"RUBYOPT" => nil, "RUBYLIB" => nil}
    stdout, stderr, child_status = Open3.capture3(environment, RbConfig.ruby, "--disable-gems", "-e", script, output)

    expect(child_status).to be_success, stderr
    expect(JSON.parse(stdout)).to eq([["LETTER", ["λ", [2, 4]]]])
  end

  it "feeds a lexer with the Ruby 2.5 Fiber API" do
    status, error = run_generate(source, "--standalone", "--target-ruby", "2.5")
    expect(status).to eq(0), error

    script = <<~RUBY
      class << Fiber
        alias_method :new_with_options, :new
        undef_method :scheduler

        def new(&body)
          new_with_options(&body)
        end
      end

      load ARGV.fetch(0)
      lexer = LegacyTargetLexer.push
      tokens = lexer.feed("é") + lexer.feed("λ!") + lexer.finish
      puts JSON.generate(tokens.map(&:value))
    RUBY
    environment = {"RUBYOPT" => nil, "RUBYLIB" => nil}
    stdout, stderr, child_status = Open3.capture3(environment, RbConfig.ruby, "--disable-gems", "-e", script, output)

    expect(child_status).to be_success, stderr
    expect(JSON.parse(stdout)).to eq(["éλ", "!"])
  end

  it "points to a Unicode property that may be unavailable in the target's regex engine" do
    spec = <<~'RUBY'
      class LegacyTargetLexer < Flexr::Lexer
        rule(/\p{Kawi}+/, emit: :LETTER)
      end
    RUBY
    status, error = run_generate(spec, "--standalone", "--target-ruby", "3.0", "--format", "json")

    expect(status).not_to eq(0)
    diagnostic = JSON.parse(error).find { |item| item.fetch("severity") == "error" }
    first, last = diagnostic.fetch("location")
    expect(spec.byteslice(first...last)).to include('\p{Kawi}')
    expect(File).not_to exist(output)
  end

  it "accepts a literal property-like string in a regular expression" do
    spec = <<~'RUBY'
      class LegacyTargetLexer < Flexr::Lexer
        rule(/\\p\{Kawi\}/, emit: :LITERAL)
      end
    RUBY
    status, error = run_generate(spec, "--standalone", "--target-ruby", "2.5")

    expect(status).to eq(0), error
  end
end
