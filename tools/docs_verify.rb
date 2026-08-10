# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require_relative "../lib/flexr"

module FlexrDocumentation
  ROOT = File.expand_path("..", __dir__)
  MARKER_START = "<!-- flexr-help:start -->"
  MARKER_END = "<!-- flexr-help:end -->"
  MARKDOWN_FILES = [
    File.join(ROOT, "README.md"),
    File.join(ROOT, "CONTRIBUTING.md"),
    *Dir[File.join(ROOT, "docs/**/*.md")],
    *Dir[File.join(ROOT, "examples/**/README.md")]
  ].freeze
  STABLE_DSL_METHODS = Flexr::DSL::DSL_METHODS - %i[compile! dfa]

  module_function

  def verify
    verify_links
    verify_english
    verify_tutorial
    verify_cli_snapshot
    verify_dsl_reference
    puts "docs: links, language, tutorial, CLI snapshot, and DSL coverage passed"
  end

  def verify_links
    MARKDOWN_FILES.each do |path|
      File.read(path).scan(/\[[^\]]+\]\(([^)\s]+)(?:\s+"[^"]*")?\)/).flatten.each do |target|
        next if target.match?(%r{\A(?:https?://|mailto:)}) || target.start_with?("#")

        local_target = target.split("#", 2).first
        resolved = File.expand_path(local_target, File.dirname(path))
        next if File.file?(resolved) || File.directory?(resolved)

        raise "broken documentation link: #{path}: #{target}"
      end
    end
  end

  def verify_english
    MARKDOWN_FILES.each do |path|
      raise "documentation contains non-English characters: #{path}" if
        File.read(path).match?(/[ぁ-んァ-ヶ一-龯]/)
    end
  end

  def verify_tutorial
    spec = File.join(ROOT, "examples/calculator/lexer.flexr.rb")
    input = "if ifx == = 12 + 3"
    expected = [["IF", "if"], ["IDENT", "ifx"], ["EQ", "=="], ["ASSIGN", "="],
                ["INTEGER", 12], ["PLUS", "+"], ["INTEGER", 3]]
    runtime = ruby_json(<<~RUBY, spec, input)
      require "json"
      load ARGV.fetch(0)
      puts JSON.generate(CalculatorExample::Lexer.new(ARGV.fetch(1)).tokens)
    RUBY
    raise "tutorial runtime output mismatch: #{runtime.inspect}" unless JSON.parse(runtime) == expected

    Dir.mktmpdir("flexr-docs") do |directory|
      output = File.join(directory, "calculator.rb")
      stdout, stderr, status = command("examples/calculator/lexer.flexr.rb", "-o", output)
      raise "tutorial generation failed: #{stderr}#{stdout}" unless status.success?

      generated = ruby_json(<<~RUBY, output, input)
        require "json"
        load ARGV.fetch(0)
        puts JSON.generate(CalculatorExample::Lexer.new(ARGV.fetch(1)).tokens)
      RUBY
      raise "tutorial runtime/generated mismatch" unless generated == runtime
    end

    stdout, stderr, status = command("check", spec, "--format", "json")
    raise "tutorial check failed: #{stderr}#{stdout}" unless status.success? && JSON.parse(stdout) == []
  end

  def verify_cli_snapshot
    output = StringIO.new
    error = StringIO.new
    status = Flexr::CLI.run(["--help"], out: output, err: error)
    raise "CLI help failed: #{error.string}" unless status.zero?

    page = File.read(File.join(ROOT, "docs/reference/cli.md"))
    snapshot = page.split(MARKER_START, 2).last&.split(MARKER_END, 2)&.first
    raise "CLI help markers are missing" unless snapshot
    raise "CLI help snapshot is stale" unless output.string == "#{snapshot.strip}\n"
  end

  def verify_dsl_reference
    page = File.read(File.join(ROOT, "docs/reference/dsl.md"))
    STABLE_DSL_METHODS.each do |method_name|
      next if page.include?("## `#{method_name}(")

      raise "stable DSL method is missing from the reference: #{method_name}"
    end
  end

  def command(*arguments)
    Open3.capture3(RbConfig.ruby, "-Ilib", "exe/flexr", *arguments, chdir: ROOT)
  end

  def ruby_json(script, path, input)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script, path, input, chdir: ROOT)
    raise "Ruby example failed: #{stderr}" unless status.success?

    stdout.strip
  end
end

FlexrDocumentation.verify
