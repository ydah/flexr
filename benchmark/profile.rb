# frozen_string_literal: true

require_relative "run"

module Flexr
  module Benchmarking
    class PhaseProfiler
      attr_reader :seconds, :elapsed

      def initialize
        @seconds = %w[scanning actions tokens locations other].to_h { |phase| [phase, 0.0] }
      end

      def measure(&)
        stack = ["other"]
        started = previous = clock
        @trace = TracePoint.new(:call, :return, :c_call, :c_return) do |event|
          now = clock
          @seconds[stack.last] += now - previous
          previous = now
          if %i[call c_call].include?(event.event)
            stack << (phase(event) || stack.last)
          elsif stack.length > 1
            stack.pop
          end
        end
        @trace.enable(target_thread: Thread.current, &)
      ensure
        @trace&.disable
        finished = clock
        @seconds[stack.last] += finished - previous
        @elapsed = finished - started
      end

      def enabled?
        @trace&.enabled? || false
      end

      private

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def phase(event)
        if event.self.is_a?(Runtime::Interpreter)
          return "scanning" if event.method_id == :scan
        elsif event.self.is_a?(Lexer)
          case event.method_id
          when :scan_one then return "scanning"
          when :execute then return "actions"
          when :emit, :text, :next_token, :tokens then return "tokens"
          when :last_location, :update_position, :advance_location! then return "locations"
          end
        end
        nil
      end
    end

    class ProfileRunner < Runner
      def run
        path = File.expand_path(@options.fetch(:spec))
        input = input_for(path)
        runtime = profile_class(load_runtime(path), input)
        generated = profile_class(load_generated(path), input)
        {
          "schema" => 1, "ruby" => RUBY_DESCRIPTION,
          "spec" => relative_path(path), "input_bytes" => input.bytesize,
          "input_sha256" => Digest::SHA256.hexdigest(input),
          "iterations" => @options.fetch(:iterations),
          "note" => "TracePoint changes execution costs and disables JIT optimizations; use phase timings only to locate work, not as throughput measurements.",
          "modes" => { "runtime" => runtime, "generated" => generated }
        }
      end

      private

      def profile_class(klass, input)
        iterations = @options.fetch(:iterations)
        klass.new(input).tokens
        profiler = PhaseProfiler.new
        tokens = profiler.measure do
          result = nil
          iterations.times { result = klass.new(input).tokens }
          result
        end
        {
          "tokens" => tokens.length,
          "instrumented_elapsed_seconds" => profiler.elapsed,
          "phase_seconds" => profiler.seconds
        }
      end
    end

    def self.profile(argv, out: $stdout, err: $stderr)
      options = parse(argv.dup)
      return usage(out) if options[:help]
      raise ArgumentError, "profiling does not support baseline checks or writes" if options[:baseline] || options[:write_baseline]

      out.puts JSON.pretty_generate(ProfileRunner.new(options).run)
      0
    rescue ArgumentError, Errno::ENOENT => e
      err.puts "profile error: #{e.message}"
      2
    end
  end
end

exit Flexr::Benchmarking.profile(ARGV) if $PROGRAM_NAME == __FILE__
