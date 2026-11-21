# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "shellwords"
require "tempfile"

module FlexrVerification
  module FailureCase
    VERSION = 1
    DIRECTORY = "tmp/verification-failures"

    module_function

    def abort_with_record(message, root:, task:, input:, expected:, actual:, **details)
      warn message
      directory = File.expand_path(ENV.fetch("FLEXR_FAILURE_DIR", DIRECTORY), root)
      record = {
        version: VERSION,
        task: task,
        revision: revision(root),
        ruby: RUBY_DESCRIPTION,
        unicode: Flexr::Unicode::VERSION,
        gems: Gem.loaded_specs.slice("bundler", "flexr", "json", "prism", "rake").transform_values { |gem| gem.version.to_s },
        **details,
        input: encode_bytes(input),
        expected: snapshot(expected),
        actual: snapshot(actual)
      }
      FileUtils.mkdir_p(directory)
      path = Tempfile.create(["#{task.tr(':', '-')}-", ".tmp"], directory) do |file|
        file.write("#{JSON.pretty_generate(record)}\n")
        file.close
        target = "#{file.path.delete_suffix('.tmp')}.json"
        File.rename(file.path, target)
        target
      end
      warn "Saved verification failure to #{path}"
      warn "Replay with FLEXR_FAILURE_CASE=#{Shellwords.escape(path)} bundle exec rake verification:replay"
      abort
    rescue SystemCallError, IOError, JSON::GeneratorError => e
      abort "Could not save verification failure: #{e.message}"
    end

    def read(path)
      record = JSON.parse(File.binread(path))
      raise ArgumentError, "unsupported verification failure format" unless record.is_a?(Hash) && record["version"] == VERSION

      number = record.fetch("case")
      raise ArgumentError, "invalid case number" unless number.is_a?(Integer) && number.positive?

      record
    end

    def section(record, name)
      value = record.fetch(name)
      raise ArgumentError, "invalid #{name} in verification failure" unless value.is_a?(Hash)

      value
    end

    def encode_bytes(string)
      { encoding: string.encoding.name, hex: string.unpack1("H*") }
    end

    def decode_bytes(record)
      hex = record.fetch("hex")
      encoding = record.fetch("encoding")
      valid_hex = hex.is_a?(String) && hex.match?(/\A[0-9a-f]*\z/) && hex.length.even?
      raise ArgumentError, "invalid encoded bytes" unless valid_hex && encoding.is_a?(String)

      [hex].pack("H*").force_encoding(Encoding.find(encoding))
    end

    def snapshot(value)
      case value
      when Hash then value.transform_values { |item| snapshot(item) }
      when Array then value.map { |item| snapshot(item) }
      when String then value.ascii_only? || (value.encoding == Encoding::UTF_8 && value.valid_encoding?) ? value : encode_bytes(value)
      when Symbol then { symbol: snapshot(value.to_s) }
      when Float then value.finite? ? value : { float: value.to_s }
      when Numeric, true, false, nil then value
      else { class: value.class.name, inspect: snapshot(value.inspect) }
      end
    end

    def revision(root)
      commit = git(root, "rev-parse", "HEAD")&.strip
      return unless commit

      diff = git(root, "diff", "--binary", "--no-ext-diff", "--no-textconv", "HEAD", "--")
      untracked = git(root, "ls-files", "--others", "--exclude-standard", "-z")
      return { commit: commit } unless diff && untracked

      digest = Digest::SHA256.new.update(diff)
      untracked.split("\0").each do |path|
        absolute = File.join(root, path)
        content = if File.symlink?(absolute)
          Digest::SHA256.hexdigest(File.readlink(absolute))
        elsif File.file?(absolute)
          Digest::SHA256.file(absolute).hexdigest
        end
        digest.update("\0#{path}\0#{content}")
      end
      { commit: commit, dirty: !diff.empty? || !untracked.empty?, worktree_sha256: digest.hexdigest }
    rescue SystemCallError
      { commit: commit } if commit
    end

    def git(root, *)
      stdout, status = Open3.capture2("git", *, chdir: root, err: File::NULL, binmode: true)
      stdout if status.success?
    rescue Errno::ENOENT
      nil
    end
  end
end
