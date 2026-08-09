# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "tempfile"

require_relative "../lib/flexr"

module Flexr
  module Benchmarking
    DEFAULT_SPEC = File.expand_path("../examples/json/lexer.flexr.rb", __dir__)
    DEFAULT_INPUTS = {
      %r{/examples/json/} => ('{"answer": 42}' * 10_000).freeze,
      %r{/examples/toy_lang/} => ("answer + 12" * 10_000).freeze
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
      status = Baseline.check(options[:baseline], result, threshold: options[:threshold])
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
        iterations: 3, threshold: 0.10, json: false, help: false
      }
      until args.empty?
        case (argument = args.shift)
        when "--help", "-h"
          options[:help] = true
        when "--spec"
          options[:spec] = required_argument!(args, argument)
        when "--input-file"
          options[:input_file] = required_argument!(args, argument)
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
        out.puts "#{mode}: #{metrics.fetch('mb_per_s')} MB/s, #{metrics.fetch('tokens_per_s')} tokens/s"
      end
    end

    def usage(out, status: 0)
      out.puts "Usage: ruby benchmark/run.rb [--spec PATH] [--baseline PATH] [--write-baseline PATH] [--json]"
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
        runtime = measure(source_path, input, generated: false)
        generated = measure(source_path, input, generated: true)
        {
          "schema" => 1,
          "spec" => relative_path(source_path),
          "source_sha256" => Digest::SHA256.hexdigest(source),
          "source_bytes" => source.bytesize,
          "input_sha256" => Digest::SHA256.hexdigest(input),
          "input_bytes" => input.bytesize,
          "tokens" => runtime.fetch("tokens"),
          "iterations" => @options.fetch(:iterations),
          "modes" => { "runtime" => runtime, "generated" => generated }
        }
      end

      private

      def input_for(source_path)
        return File.binread(@options.fetch(:input_file)) if @options[:input_file]

        DEFAULT_INPUTS.each do |pattern, input|
          return input if source_path.match?(pattern)
        end
        raise ArgumentError, "--input-file is required for #{source_path}"
      end

      def measure(source_path, input, generated:)
        klass = generated ? load_generated(source_path) : load_runtime(source_path)
        iterations = @options.fetch(:iterations)
        iterations.times { klass.new(input).tokens }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        tokens = nil
        iterations.times { tokens = klass.new(input).tokens }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        bytes_per_second = input.bytesize * iterations / [elapsed, Float::EPSILON].max
        token_count = tokens.length
        {
          "tokens" => token_count,
          "mb_per_s" => (bytes_per_second / 1_000_000).round(3),
          "tokens_per_s" => (token_count * iterations / [elapsed, Float::EPSILON].max).round
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
      module_function

      def check(path, result, threshold:)
        return 0 unless path
        return 2 unless File.file?(path)

        baseline = JSON.parse(File.read(path))
        return 2 unless baseline["schema"] == 1
        return 1 unless identity_matches?(baseline, result)

        baseline.fetch("modes").each do |mode, metrics|
          expected = Float(metrics.fetch("mb_per_s"))
          actual = Float(result.fetch("modes").fetch(mode).fetch("mb_per_s"))
          return 1 if actual < expected * (1.0 - threshold)
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
        %w[spec source_sha256 source_bytes input_sha256 input_bytes tokens].all? do |key|
          baseline[key] == result[key]
        end
      end
    end
  end
end

exit Flexr::Benchmarking.run(ARGV) if $PROGRAM_NAME == __FILE__
