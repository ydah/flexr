# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tempfile"
require "tmpdir"

require_relative "../lib/flexr"
require_relative "baselines/json_handwritten"

module Flexr
  module Benchmarking
    DEFAULT_SPEC = File.expand_path("../examples/json/lexer.flexr.rb", __dir__)
    INPUT_MODES = %w[frozen mutable].freeze
    DEFAULT_INPUTS = {
      %r{/examples/json/} => ('{"answer": 42}' * 10_000).freeze,
      %r{/examples/toy_lang/} => ("answer + 12" * 10_000).freeze,
      %r{/examples/toml/} => ('title = "flexr" ' * 10_000).freeze,
      %r{/examples/graphql/} => ('query { user(id: 12) { name } } ' * 10_000).freeze,
      %r{/examples/sql/} => ('select name from users where id >= 12; ' * 10_000).freeze,
      %r{/examples/ruby_subset/} => ('class Foo "ok" end ' * 10_000).freeze
    }.freeze

    module_function

    def run(argv, out: $stdout, err: $stderr)
      options = parse(argv.dup)
      return usage(out) if options[:help]
      if options[:baseline] && !File.file?(options[:baseline])
        err.puts "benchmark error: baseline is missing or invalid"
        return 2
      end

      result = Runner.new(options).run
      Baseline.write(options[:write_baseline], result) if options[:write_baseline]
      floor = ENV["FLEXR_BENCHMARK_PORTABLE"] == "1" ? 0.0 : Baseline::PERFORMANCE_FLOOR
      status = Baseline.check(options[:baseline], result, threshold: options[:threshold], floor: floor)
      emit(result, out, json: options[:json])
      return status if status.zero?

      err.puts status == 2 ? "benchmark error: baseline is missing or invalid" : "benchmark regression detected"
      status
    rescue ArgumentError => e
      err.puts "benchmark error: #{e.message}"
      usage(err, status: 2)
    rescue Errno::ENOENT => e
      err.puts "benchmark error: #{e.message}"
      2
    rescue StandardError => e
      err.puts "benchmark error: #{e.class}: #{e.message}"
      1
    end

    def parse(args)
      options = {
        spec: DEFAULT_SPEC, input_file: nil, baseline: nil, write_baseline: nil,
        iterations: 3, threshold: 0.10, json: false, help: false, input_mode: nil, verify_parity: false
      }
      until args.empty?
        case (argument = args.shift)
        when "--help", "-h"
          options[:help] = true
        when "--spec"
          options[:spec] = required_argument!(args, argument)
        when "--input-file"
          options[:input_file] = required_argument!(args, argument)
        when "--input-mode"
          mode = required_argument!(args, argument)
          raise ArgumentError, "--input-mode must be frozen or mutable" unless INPUT_MODES.include?(mode)

          options[:input_mode] = mode
        when "--verify-parity"
          options[:verify_parity] = true
        when "--baseline"
          options[:baseline] = required_argument!(args, argument)
        when "--write-baseline"
          options[:write_baseline] = required_argument!(args, argument)
        when "--iterations"
          options[:iterations] = Integer(required_argument!(args, argument), 10)
          raise ArgumentError, "iterations must be positive" unless options[:iterations].positive?
        when "--threshold"
          options[:threshold] = Float(required_argument!(args, argument))
          raise ArgumentError, "threshold must be between 0 and 1" unless options[:threshold].between?(0, 1)
        when "--json"
          options[:json] = true
        else
          raise ArgumentError, "unknown option: #{argument}"
        end
      end
      options
    end

    def required_argument!(args, option)
      value = args.shift
      raise ArgumentError, "#{option} requires a value" if value.nil? || value.start_with?("-")

      value
    end

    def emit(result, out, json:)
      if json
        out.puts JSON.pretty_generate(result)
        return
      end

      out.puts "spec: #{result.fetch('spec')}"
      out.puts "input_bytes: #{result.fetch('input_bytes')}, tokens: #{result.fetch('tokens')}"
      result.fetch("modes").each do |mode, metrics|
        out.puts "#{mode}: #{metrics.fetch('mb_per_s')} MB/s, #{metrics.fetch('tokens_per_s')} tokens/s, " \
          "#{metrics.fetch('allocations_per_token')} allocations/token"
      end
      if (ratios = result["relative_to_handwritten"])
        out.puts "relative_to_handwritten: runtime=#{ratios.fetch('runtime')}x, generated=#{ratios.fetch('generated')}x"
      end
    end

    def usage(out, status: 0)
      out.puts "Usage: ruby benchmark/run.rb [--spec PATH] [--input-file PATH] [--input-mode frozen|mutable] " \
               "[--verify-parity] [--baseline PATH] [--write-baseline PATH] [--json]"
      status
    end

    class Runner
      def initialize(options)
        @options = options
      end

      def run
        source_path = File.expand_path(@options.fetch(:spec))
        source = File.binread(source_path)
        input = input_for(source_path)
        runtime_class = load_runtime(source_path)
        runtime = measure_class(runtime_class, input)
        expected = token_digest(runtime_class, input) if @options[:verify_parity]
        generated_class = load_generated(source_path)
        generated = measure_class(generated_class, input)
        verify_parity(source_path, generated_class, input, expected) if expected
        {
          "schema" => 1,
          "spec" => relative_path(source_path),
          "source_sha256" => Digest::SHA256.hexdigest(source),
          "source_bytes" => source.bytesize,
          "input_sha256" => Digest::SHA256.hexdigest(input),
          "input_bytes" => input.bytesize,
          "input_mode" => input.frozen? ? "frozen" : "mutable",
          "tokens" => runtime.fetch("tokens"),
          "iterations" => @options.fetch(:iterations),
          "modes" => { "runtime" => runtime, "generated" => generated }
        }.tap do |result|
          result["parity_verified"] = true if expected
          next unless source_path.match?(%r{/examples/json/})

          handwritten = measure_class(FlexrBenchmark::JsonHandwrittenLexer, input)
          result["modes"]["handwritten"] = handwritten
          result["relative_to_handwritten"] = {
            "runtime" => (runtime.fetch("mb_per_s") / handwritten.fetch("mb_per_s")).round(3),
            "generated" => (generated.fetch("mb_per_s") / handwritten.fetch("mb_per_s")).round(3)
          }
        end
      end

      private

      def input_for(source_path)
        input = if @options[:input_file]
          File.binread(@options.fetch(:input_file))
        else
          DEFAULT_INPUTS.find { |pattern, _| source_path.match?(pattern) }&.last
        end
        raise ArgumentError, "--input-file is required for #{source_path}" unless input

        case @options[:input_mode]
        when "frozen" then input.freeze
        when "mutable" then input.dup
        else input
        end
      end

      def token_digest(klass, input)
        digest = Digest::SHA256.new
        # Hash tokens separately so equal values can share objects across tokens.
        klass.new(input).tokens.each { |token| digest << Marshal.dump(token) }
        digest.hexdigest
      end

      def verify_parity(source_path, generated_class, input, expected)
        raise "generated token parity failed for #{source_path}" unless token_digest(generated_class, input) == expected

        Dir.mktmpdir("flexr-benchmark-parity-") do |directory|
          standalone = File.join(directory, "standalone.rb")
          bytes = File.join(directory, "input.dat")
          File.binwrite(standalone, Flexr::Generator.new(source_path, options: { standalone: true }).generate)
          File.binwrite(bytes, input)
          program = <<~RUBY
            require ARGV.fetch(0)
            bytes = File.binread(ARGV.fetch(1)).force_encoding(ARGV.fetch(3))
            bytes.freeze if ARGV.fetch(4) == "frozen"
            digest = Digest::SHA256.new
            Object.const_get(ARGV.fetch(2)).new(bytes).tokens.each { |token| digest << Marshal.dump(token) }
            puts digest.hexdigest
          RUBY
          engine = if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
            "--yjit"
          elsif defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?
            "--zjit"
          else
            "--disable=yjit,zjit"
          end
          mode = input.frozen? ? "frozen" : "mutable"
          stdout, stderr, status = Open3.capture3({ "RUBYOPT" => nil, "RUBYLIB" => nil }, RbConfig.ruby, "--disable-gems", engine,
                                                "-rdigest", "-e", program, standalone, bytes, generated_class.name,
                                                input.encoding.name, mode)
          raise "standalone token parity failed for #{source_path}: #{stderr}" unless status.success? && stdout.strip == expected
        end
      end

      def measure_class(klass, input)
        iterations = @options.fetch(:iterations)
        iterations.times { klass.new(input).tokens }
        GC.start
        allocated_before = GC.stat.fetch(:total_allocated_objects)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        tokens = nil
        iterations.times { tokens = klass.new(input).tokens }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        allocated = GC.stat.fetch(:total_allocated_objects) - allocated_before
        bytes_per_second = input.bytesize * iterations / [elapsed, Float::EPSILON].max
        token_count = tokens.length
        {
          "tokens" => token_count,
          "mb_per_s" => (bytes_per_second / 1_000_000).round(3),
          "tokens_per_s" => (token_count * iterations / [elapsed, Float::EPSILON].max).round,
          "allocations_per_token" => (allocated.to_f / [token_count * iterations, 1].max).round(3)
        }
      end

      def load_runtime(source_path)
        before = lexer_classes
        load source_path
        @runtime_class = lexer_classes.difference(before).last
        @runtime_class || raise(ArgumentError, "no lexer class found in #{source_path}")
      end

      def load_generated(source_path)
        generated = Flexr::Generator.new(source_path).generate
        remove_constant(@runtime_class.name) if @runtime_class
        before = lexer_classes
        Tempfile.create(["flexr-benchmark-", ".rb"]) do |file|
          file.write(generated)
          file.flush
          load file.path
        end
        (lexer_classes - before).last || raise(ArgumentError, "generated lexer class not found")
      end

      def lexer_classes
        ObjectSpace.each_object(Class).select { |klass| klass.respond_to?(:__flexr_spec) }
      end

      def remove_constant(name)
        parts = name.split("::")
        parent = Object
        parts[0...-1].each { |part| parent = parent.const_get(part) }
        parent.send(:remove_const, parts.last) if parent.const_defined?(parts.last, false)
      end

      def relative_path(path)
        root = File.expand_path("..", __dir__)
        path.start_with?("#{root}/") ? path.delete_prefix("#{root}/") : path
      end
    end

    module Baseline
      PERFORMANCE_FLOOR = 0.18
      FLOOR_MODES = %w[runtime generated].freeze

      module_function

      def check(path, result, threshold:, floor: PERFORMANCE_FLOOR)
        return 0 unless path
        return 2 unless File.file?(path)

        baseline = JSON.parse(File.read(path))
        return 2 unless baseline["schema"] == 1
        return 1 unless identity_matches?(baseline, result)

        baseline_ratios = baseline.fetch("relative_to_handwritten")
        FLOOR_MODES.each do |mode|
          actual = Float(result.fetch("relative_to_handwritten").fetch(mode))
          expected = Float(baseline_ratios.fetch(mode)) * (1.0 - threshold)
          return 1 if actual < [floor, expected].max
        end
        0
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError
        2
      end

      def write(path, result)
        FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
        File.write(path, "#{JSON.pretty_generate(result)}\n")
      end

      def identity_matches?(baseline, result)
        return false if baseline.key?("input_mode") && baseline["input_mode"] != result["input_mode"]

        %w[spec source_sha256 source_bytes input_sha256 input_bytes tokens].all? do |key|
          baseline[key] == result[key]
        end
      end
    end
  end
end

exit Flexr::Benchmarking.run(ARGV) if $PROGRAM_NAME == __FILE__
