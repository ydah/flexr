# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "load boundaries" do
  let(:lib) { File.expand_path("../lib", __dir__) }

  it "keeps build tools and Unicode tables out of the default runtime load" do
    script = <<~'RUBY'
      require "flexr"
      forbidden = %w[
        flexr/generator.rb flexr/cli.rb flexr/importer.rb flexr/rake_task.rb
        flexr/source.rb flexr/codegen.rb unicode/data/properties.rb unicode/data/case_folding.rb
      ]
      loaded = $LOADED_FEATURES.select { |path| forbidden.any? { |suffix| path.end_with?(suffix) } }
      abort "eagerly loaded: #{loaded.join(', ')}" unless loaded.empty?
      abort "generator autoload is missing" unless Flexr.autoload?(:Generator)

      class LoadBoundaryLexer < Flexr::Lexer
        rule(/[a-z]+/) { emit :WORD }
      end
      abort "wrong runtime tokens" unless LoadBoundaryLexer.new("abc").tokens == [[:WORD, "abc"]]
      loaded = $LOADED_FEATURES.select { |path| forbidden.any? { |suffix| path.end_with?(suffix) } }
      abort "ASCII compilation loaded optional files: #{loaded.join(', ')}" unless loaded.empty?
    RUBY

    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)
    expect(status).to be_success, stderr
  end

  it "provides independent runtime, generator, and CLI entrypoints" do
    scripts = [
      'require "flexr/runtime"; abort unless defined?(Flexr::Lexer)',
      'require "flexr/generator"; abort unless defined?(Flexr::Generator)',
      'require "flexr/cli"; abort unless defined?(Flexr::CLI)'
    ]

    scripts.each do |script|
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)
      expect(status).to be_success, stderr
    end
  end
end
