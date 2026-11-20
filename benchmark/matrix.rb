# frozen_string_literal: true

require "open3"
require "rbconfig"
require_relative "run"

module Flexr
  module Benchmarking
    class RubyMatrix
      ROOT = File.expand_path("..", __dir__)
      FLAGS = { "interpreter" => ["--disable=yjit,zjit"], "yjit" => ["--yjit"], "zjit" => ["--zjit"] }.freeze
      PROBE = <<~RUBY
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

      def run(engines: FLAGS.keys)
        results = engines.to_h do |engine|
          availability = @probe.call(engine)
          result = if availability.fetch("available")
            { "status" => "measured", "ruby" => availability["ruby"], "result" => @benchmark.call(engine) }
          else
            { "status" => "unavailable", "reason" => availability.fetch("reason") }
          end
          [engine, result]
        end
        { "schema" => 1, "engines" => results }
      end

      def self.command(argv, out: $stdout, err: $stderr)
        options = Benchmarking.parse(argv.dup)
        return Benchmarking.usage(out) if options[:help]
        raise ArgumentError, "matrix results cannot share a baseline output file" if options[:write_baseline]

        out.puts JSON.pretty_generate(new(arguments: argv).run)
        0
      rescue ArgumentError, Errno::ENOENT => e
        err.puts "matrix error: #{e.message}"
        2
      rescue RuntimeError => e
        err.puts "matrix error: #{e.message}"
        1
      end

      private

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
