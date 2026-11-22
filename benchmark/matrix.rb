# frozen_string_literal: true

require "open3"
require "rbconfig"
require_relative "run"

module Flexr
  module Benchmarking
    class RubyMatrix
      ROOT = File.expand_path("..", __dir__)
      FLAGS = { "interpreter" => ["--disable=yjit,zjit"], "yjit" => ["--yjit"], "zjit" => ["--zjit"] }.freeze
      PROBE = <<~RUBY.lines.map(&:strip).join(";").freeze
        require "json"
        engine = ARGV.fetch(0)
        enabled = case engine
        when "interpreter"
          !(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?) && !(defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?)
        when "yjit" then defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
        when "zjit" then defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?
        end
        puts JSON.generate(available: !!enabled, ruby: RUBY_DESCRIPTION, reason: enabled ? nil : "engine is not enabled by this Ruby build")
      RUBY

      def initialize(arguments: [], probe: nil, benchmark: nil)
        @arguments = arguments
        @probe = probe || method(:probe_engine)
        @benchmark = benchmark || method(:benchmark_engine)
      end

      def run(engines: FLAGS.keys, verify_ratio: false)
        results = engines.to_h do |engine|
          availability = @probe.call(engine)
          result = if availability.fetch("available")
            measurement = verify_ratio ? measure_ratio(engine) : { "result" => @benchmark.call(engine) }
            { "status" => "measured", "ruby" => availability["ruby"], **measurement }
          else
            { "status" => "unavailable", "reason" => availability.fetch("reason") }
          end
          [engine, result]
        end
        report = { "schema" => 1, "engines" => results }
        if verify_ratio
          failed = results.keys.reject { |engine| results.fetch(engine).fetch("median_generated_runtime_ratio", 0) >= 1.0 }
          report["generated_runtime_ratio_check"] = { "minimum" => 1.0, "passed" => failed.empty?, "failed_engines" => failed }
        end
        report
      end

      def self.command(argv, out: $stdout, err: $stderr)
        options = Benchmarking.parse(argv.dup)
        return Benchmarking.usage(out) if options[:help]
        raise ArgumentError, "matrix results cannot share a baseline output file" if options[:write_baseline]

        verify_ratio = ENV["FLEXR_BENCHMARK_CHECK_MATRIX"] == "1"
        report = new(arguments: argv).run(verify_ratio: verify_ratio)
        out.puts JSON.pretty_generate(report)
        if (check = report["generated_runtime_ratio_check"]) && !check.fetch("passed")
          err.puts "matrix error: generated/runtime ratio check failed for #{check.fetch('failed_engines').join(', ')}"
          return 1
        end
        0
      rescue ArgumentError, Errno::ENOENT => e
        err.puts "matrix error: #{e.message}"
        2
      rescue RuntimeError => e
        err.puts "matrix error: #{e.message}"
        1
      end

      private

      def measure_ratio(engine)
        samples = Array.new(3) { @benchmark.call(engine) }
        ratios = samples.map do |sample|
          modes = sample.fetch("modes")
          runtime = modes.fetch("runtime").fetch("tokens_per_s")
          generated = modes.fetch("generated").fetch("tokens_per_s")
          runtime.positive? ? generated.fdiv(runtime) : 0.0
        end
        median = ratios.each_index.sort_by { |index| ratios.fetch(index) }.fetch(1)
        {
          "result" => samples.fetch(median), "ratio_samples" => ratios,
          "median_generated_runtime_ratio" => ratios.fetch(median)
        }
      end

      def probe_engine(engine)
        stdout, stderr, status = Open3.capture3({ "RUBYOPT" => nil }, RbConfig.ruby, *FLAGS.fetch(engine),
                                                "-e", PROBE, engine, chdir: ROOT)
        return { "available" => false, "reason" => stderr.strip } unless status.success?

        JSON.parse(stdout)
      end

      def benchmark_engine(engine)
        stdout, stderr, status = Open3.capture3({ "RUBYOPT" => nil }, RbConfig.ruby, *FLAGS.fetch(engine),
                                                "-Ilib", "benchmark/run.rb", *@arguments, "--json", chdir: ROOT)
        raise "#{engine} benchmark failed (#{status.exitstatus}): #{stderr}#{stdout}" unless status.success?

        JSON.parse(stdout)
      end
    end
  end
end

exit Flexr::Benchmarking::RubyMatrix.command(ARGV) if $PROGRAM_NAME == __FILE__
