# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

module Flexr
  class Skeleton
    class Verification
      MODES = %i[runtime generated standalone].freeze
      RUNNER = <<~RUBY
        require "json"
        mode, path, origin, class_name, snapshot_path, result_path = ARGV
        request = JSON.parse(STDIN.binmode.read)
        require "flexr" unless mode == "standalone"
        if mode == "runtime"
          load origin
        else
          eval(File.read(path, encoding: "UTF-8"), TOPLEVEL_BINDING, origin, 1)
        end
        require snapshot_path
        snapshot = Flexr::Testing::Snapshot
        klass = class_name.split("::").reject(&:empty?).inject(Object) { |scope, name| scope.const_get(name, false) }
        config = klass.__flexr_config
        if mode == "runtime"
          request.fetch("runtime_options").each { |method, value| klass.public_send(method, value.to_sym) }
          limit = request["max_dfa_states"]
          config.options[:max_dfa_states] = limit if limit
        end
        outcomes = request.fetch("cases").map do |item|
          value = item.fetch("input")
          input = value.is_a?(String) ? value : value.fetch("bytes").pack("C*")
          lexer = klass.new(input.force_encoding(config.encoding), filename: origin)
          lexer.begin_state(item.fetch("state").to_sym)
          tokens = []
          error = begin
            while (token = lexer.next_token)
              tokens << token
            end
            nil
          rescue StandardError => caught
            report = { class: caught.class.name, message: snapshot.encode(caught.message) }
            %i[filename byte_pos line text rule].each do |field|
              report[field] = snapshot.encode(caught.public_send(field)) if caught.respond_to?(field)
            end
            report[:code] = caught.diagnostic&.code if caught.respond_to?(:diagnostic)
            report
          end
          { tokens: snapshot.encode(tokens), state: lexer.state, byte_pos: lexer.byte_pos, error: error }
        end
        File.binwrite(result_path, JSON.generate(outcomes))
      RUBY

      def initialize(spec, class_name:, options:)
        @spec = File.expand_path(spec)
        @class_name = class_name
        @options = options
      end

      def compare(cases)
        outcomes = Dir.mktmpdir("flexr-skeleton-verify-") do |directory|
          request = {
            cases: cases.map { |item| item.slice(:state, :input) },
            runtime_options: @options.slice(:backend, :token_kind, :accel),
            max_dfa_states: @options[:max_dfa_states]
          }
          MODES.to_h { |mode| [mode, run_mode(mode, directory, request)] }
        end
        mismatches = cases.each_with_index.filter_map do |item, index|
          results = outcomes.transform_values { |entries| entries.fetch(index) }
          next if results.values.uniq.one?

          item.slice(:state, :input).merge(outcomes: results)
        end
        { modes: MODES, compared: cases.size, matched: cases.size - mismatches.size, mismatches: mismatches }
      end

      private

      def run_mode(mode, directory, request)
        source_path = @spec
        if mode != :runtime
          source_path = File.join(directory, "#{mode}.rb")
          options = @options.merge(standalone: mode == :standalone)
          Generator.new(@spec, output: source_path, options: options).generate
        end
        result_path = File.join(directory, "#{mode}.json")
        snapshot_path = File.expand_path("../testing.rb", __dir__)
        command = [RbConfig.ruby]
        command.push("-I", File.expand_path("../..", __dir__)) unless mode == :standalone
        command.push("-e", RUNNER, mode.to_s, source_path, @spec, @class_name, snapshot_path, result_path)
        _, stderr, status = Open3.capture3(*command, stdin_data: JSON.generate(request), binmode: true)
        unless status.success? && File.file?(result_path)
          detail = stderr.lines.first&.strip
          detail = "worker exited without producing a report (#{status})" if detail.nil? || detail.empty?
          raise CompileError, "skeleton #{mode} verification failed: #{detail}"
        end

        JSON.parse(File.binread(result_path))
      end
    end
  end
end
