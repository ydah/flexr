# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "tmpdir"
require "flexr"

module Flexr
  module Benchmarking
    class FeatureCostChild < Flexr::Lexer
      rule(/[a-z]+/, emit: :WORD)
    end

    module FeatureCosts
      SKIP_SPACE = 'rule(/ +/, skip: true)'
      WORD = 'rule(/[a-z]+/, emit: :WORD)'
      LAYOUT = 'rule(/\n/, emit: :NL)'
      MODES = %w[runtime generated].freeze
      VARIANTS = %w[without with].freeze

      CASES = {
        "captures" => [
          "alpha beta ",
          ['rule(/[a-z]+/) { emit :WORD, text }', SKIP_SPACE],
          ['rule(/(?<word>[a-z]+)/) { emit :WORD, captures.fetch(:word) }', SKIP_SPACE]
        ],
        "channels" => [
          "alpha  beta ",
          [WORD, 'rule(/ +/, emit: :SPACE)'],
          [WORD, 'rule(/ +/, channel: :trivia, emit: :SPACE)']
        ],
        "expect" => ["alpha beta ", [WORD, SKIP_SPACE], [WORD, SKIP_SPACE]],
        "keywords" => [
          "if alpha else beta ",
          ['KEYWORDS = {"if" => :IF, "else" => :ELSE}.freeze', 'rule(/[a-z]+/) { emit KEYWORDS.fetch(text, :WORD) }', SKIP_SPACE],
          [WORD, 'keywords %w[if else], among: :WORD', SKIP_SPACE]
        ],
        "priority" => [
          "alpha if beta ",
          ['rule("if", emit: :IF)', WORD, SKIP_SPACE],
          ['rule("if", emit: :IF, priority: 1)', WORD, SKIP_SPACE]
        ],
        "pattern_algebra" => [
          "abc ab c ",
          ['rule(/[a-c]+/, emit: :WORD)', SKIP_SPACE],
          ['rule(pattern(/[a-z]+/) & pattern(/[a-c]+/), emit: :WORD)', SKIP_SPACE]
        ],
        "delegation" => [
          "[alpha][beta]",
          ['rule(/\[[a-z]+\]/) { emit :WORD, text.byteslice(1...-1) }'],
          ['rule(/\[(?<word>[a-z]+)\]/) { delegate Flexr::Benchmarking::FeatureCostChild, capture: :word }']
        ],
        "indentation" => [
          "root\n  child\n#end\n",
          [WORD, LAYOUT, 'rule("  ") { emit :IN, nil }', 'rule("#") { emit :OUT, nil }'],
          [WORD, LAYOUT, 'indentation newline: :NL, indent: :IN, dedent: :OUT', SKIP_SPACE, 'rule("#", skip: true)']
        ],
        "push_input" => [
          "@ tail ",
          [WORD, SKIP_SPACE, 'rule("@") { emit :WORD, "alpha" }'],
          [WORD, SKIP_SPACE, 'rule("@") { push_input("alpha") }']
        ]
      }.freeze

      module_function

      def command(argv, out: $stdout, err: $stderr)
        options = { iterations: 3, repeats: 2_000, input_mode: "frozen", threshold: 0.01 }
        parser = OptionParser.new do |cli|
          cli.banner = "Usage: ruby -Ilib benchmark/feature_costs.rb [options]"
          cli.on("--iterations N", Integer) { |value| options[:iterations] = value }
          cli.on("--repeats N", Integer) { |value| options[:repeats] = value }
          cli.on("--input-mode MODE", %w[frozen mutable]) { |value| options[:input_mode] = value }
          cli.on("--baseline PATH") { |value| options[:baseline] = value }
          cli.on("--threshold FRACTION", Float) { |value| options[:threshold] = value }
          cli.on("-h", "--help") do
            out.puts cli
            return 0
          end
        end
        unused = parser.parse(argv)
        raise ArgumentError, "unexpected arguments: #{unused.join(' ')}" unless unused.empty?
        raise ArgumentError, "iterations and repeats must be positive" unless options.values_at(:iterations, :repeats).all?(&:positive?)
        raise ArgumentError, "threshold must be between 0 and 1" unless options[:threshold].between?(0, 1)

        baseline = JSON.parse(File.read(options[:baseline])) if options[:baseline]
        FeatureCostChild.compile!
        report = { "schema" => 1, "ruby" => RUBY_DESCRIPTION, "engine" => engine, "input_mode" => options.fetch(:input_mode) }
        report["features"] = CASES.to_h do |name, (fragment, *bodies)|
          input = fragment * options.fetch(:repeats)
          input.freeze if options[:input_mode] == "frozen"
          [name, measure(name, bodies, input, options.fetch(:iterations))]
        end
        check = compare_unused(baseline, report, options.fetch(:threshold)) if options[:baseline]
        report["unused_regression_check"] = check if check
        out.puts JSON.pretty_generate(report)
        check && !check.fetch("passed") ? 1 : 0
      rescue ArgumentError, OptionParser::ParseError, SystemCallError, JSON::ParserError => e
        err.puts "feature benchmark error: #{e.message}"
        2
      rescue RuntimeError => e
        err.puts "feature benchmark error: #{e.message}"
        1
      end

      def engine
        return "yjit" if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
        return "zjit" if defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?

        "interpreter"
      end

      def measure(name, bodies, input, iterations)
        runtime_and_generated = {}
        token_digests = {}
        Dir.mktmpdir("flexr-feature-costs") do |directory|
          VARIANTS.zip(bodies).each do |variant, body|
            path = File.join(directory, "#{variant}.flexr.rb")
            source = "# frozen_string_literal: true\n\nclass FeatureLexer < Flexr::Lexer\n  #{body.join("\n  ")}\nend\n"
            File.binwrite(path, source)
            runtime_and_generated[variant] = MODES.to_h do |mode|
              started = monotonic
              namespace = Module.new
              code = mode == "generated" ? Flexr::Generator.new(path).generate : source
              namespace.module_eval(code, path, 1)
              scanner = namespace.const_get(:FeatureLexer, false)
              scanner.compile!
              prepare = monotonic - started
              tokenize = -> { tokens(scanner.new(input), name, variant) }
              tokens = tokenize.call
              raise "#{name}/#{variant}/#{mode} returned no tokens" if tokens.empty?

              digest = Digest::SHA256.new
              tokens.each { |token| digest << Marshal.dump(token) }
              token_digests[[variant, mode]] = digest.hexdigest
              rate = throughput(tokenize, input.bytesize, iterations)
              [mode, { "prepare_seconds" => prepare, "bytes_per_second" => rate }]
            end
          end
        end
        raise "#{name} produced different tokens across variants or scanner modes" unless token_digests.values.uniq.one?

        runtime_and_generated.merge(
          "parity_verified" => true,
          "fixture_sha256" => Digest::SHA256.hexdigest(Marshal.dump([name, bodies, input, token_digests.values.first])),
          "with_without_ratios" => MODES.to_h do |mode|
            active = runtime_and_generated.fetch("with").fetch(mode).fetch("bytes_per_second")
            control = runtime_and_generated.fetch("without").fetch(mode).fetch("bytes_per_second")
            [mode, active / control]
          end
        )
      end

      def tokens(scanner, name, variant)
        return scanner.tokens if variant == "without"

        case name
        when "channels" then scanner.tokens(channels: :all)
        when "expect"
          output = []
          while (token = scanner.next_token(expect: [:WORD]))
            output << token
          end
          output
        else
          scanner.tokens
        end
      end

      def throughput(tokenize, input_bytes, iterations)
        iterations.times { tokenize.call }
        rates = Array.new(3) do
          GC.start
          started = monotonic
          iterations.times { tokenize.call }
          input_bytes * iterations / (monotonic - started)
        end
        rates.sort.fetch(1)
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def compare_unused(baseline, report, threshold)
        keys = %w[schema ruby engine input_mode]
        raise ArgumentError, "baseline differs in #{keys.join(', ')}" unless baseline.is_a?(Hash) &&
          baseline.values_at(*keys) == report.values_at(*keys)

        minimum = 1 - threshold
        features = baseline.fetch("features")
        failed = report.fetch("features").flat_map do |name, result|
          previous = features.fetch(name)
          raise ArgumentError, "#{name} baseline fixture differs" unless previous.fetch("fixture_sha256") == result.fetch("fixture_sha256")

          MODES.filter_map do |mode|
            before = previous.fetch("without").fetch(mode).fetch("bytes_per_second")
            raise ArgumentError, "invalid #{name}/#{mode} baseline throughput" unless before.is_a?(Numeric) && before.positive? && before.finite?

            ratio = result.fetch("without").fetch(mode).fetch("bytes_per_second") / before
            { "feature" => name, "mode" => mode, "ratio" => ratio } if ratio < minimum
          end
        end
        { "minimum" => minimum, "passed" => failed.empty?, "failures" => failed }
      rescue KeyError, NoMethodError, TypeError
        raise ArgumentError, "baseline is missing feature measurements"
      end
    end
  end
end

exit Flexr::Benchmarking::FeatureCosts.command(ARGV) if $PROGRAM_NAME == __FILE__
