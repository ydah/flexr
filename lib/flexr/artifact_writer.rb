# frozen_string_literal: true

require "tempfile"

module Flexr
  module ArtifactWriter
    module_function

    def default_generated_path(source_path)
      return source_path.sub(/\.flexr\.rb\z/, ".rb") if source_path.end_with?(".flexr.rb")
      return source_path.sub(/\.rb\z/, ".generated.rb") if source_path.end_with?(".rb")

      "#{source_path}.generated.rb"
    end

    def write!(path, content, source_path: nil)
      ensure_distinct!(source_path, path) if source_path
      return :unchanged if File.file?(path) && File.binread(path) == content.b

      atomic_replace(path, content)
      :written
    end

    def ensure_distinct!(source_path, output_path)
      same_path = File.expand_path(source_path) == File.expand_path(output_path)
      same_file = File.exist?(source_path) && File.exist?(output_path) && File.identical?(source_path, output_path)
      return unless same_path || same_file

      raise ArgumentError, "refusing to overwrite input file: #{source_path}"
    end

    def atomic_replace(path, content)
      expanded = File.expand_path(path)
      directory = File.dirname(expanded)
      basename = File.basename(expanded)
      mode = File.exist?(expanded) ? File.stat(expanded).mode & 0o7777 : 0o666 & ~File.umask
      temporary_path = nil

      Tempfile.create([".#{basename}.", ".tmp"], directory, binmode: true) do |temporary|
        temporary_path = temporary.path
        temporary.write(content)
        temporary.flush
        temporary.fsync
        temporary.chmod(mode)
        temporary.close
        File.rename(temporary_path, expanded)
        temporary_path = nil
      end
      sync_directory(directory)
    ensure
      File.unlink(temporary_path) if temporary_path && File.exist?(temporary_path)
    end

    def sync_directory(directory)
      File.open(directory, File::RDONLY, &:fsync)
    rescue SystemCallError, IOError
      # Some supported filesystems do not allow fsync on directories. The file
      # itself has already been synced before the atomic rename.
    end
  end
end
