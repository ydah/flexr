# frozen_string_literal: true

module Flexr
  module ProjectTemplate
    ROOT = File.join(__dir__, "project_templates")
    NAME = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
    PARSERS = %w[lrama racc].freeze
    COMMON_FILES = %w[.gitignore lexer.flexr.rb test_calculator.rb].freeze
    PARSER_FILES = %w[Gemfile README.md Rakefile calculator.rb parser.y].freeze

    module_function

    def create(name, parser:)
      raise ArgumentError, "project name must start with a letter or digit and contain only letters, digits, hyphens, or underscores" unless
        NAME.match?(name)
      raise ArgumentError, "--parser must be lrama or racc" unless PARSERS.include?(parser)

      files = COMMON_FILES.to_h { |file| [file, File.binread(File.join(ROOT, "common", file))] }
      PARSER_FILES.each { |file| files[file] = File.binread(File.join(ROOT, parser, file)) }
      destination = File.expand_path(name)
      create_directory(destination)
      write_files(destination, files)
    end

    def create_directory(destination)
      Dir.mkdir(destination)
    rescue Errno::EEXIST
      raise Flexr::Error, "project path already exists: #{destination}"
    end

    def write_files(destination, files)
      written = []
      files.each do |name, content|
        path = File.join(destination, name)
        File.open(path, "wbx") do |file|
          written << path
          file.write(content)
        end
      end
    rescue SystemCallError, IOError
      written.reverse_each { |path| File.unlink(path) }
      Dir.rmdir(destination) if Dir.empty?(destination)
      raise
    end
  end
end
