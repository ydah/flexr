# frozen_string_literal: true

require "json"
require "rbconfig"
require "tmpdir"
require_relative "regexp_parser_scanner"

module RegexpParserParity
  VERSION = "2.13.4"

  def self.run(upstream, suite: "spec")
    upstream = File.expand_path(upstream)
    gem "regexp_parser", VERSION
    require "regexp_parser"
    abort "Expected regexp_parser #{VERSION}, got #{Regexp::Parser::VERSION}" unless Regexp::Parser::VERSION == VERSION

    calls, cases = corpus(upstream, suite)
    results = { exact: 0, unsupported: 0, token_mismatch: 0, upstream_error: 0 }
    findings = {}
    cases.sort_by { |input, options| [input.inspect.length, input.inspect, options.to_i] }.each do |input, options|
      kind, reason, difference = compare(input, options)
      results[kind] += 1
      next if kind == :exact

      finding = findings[[kind, reason]] ||= {
        result: kind, reason: reason, count: 0,
        sample: { input: input.inspect, encoding: input.encoding.name, options: options }, difference: difference
      }
      finding[:count] += 1
    end
    {
      regexp_parser: VERSION, ruby: RUBY_VERSION, suite: suite, scanner_calls: calls, unique_requests: cases.length,
      results: results, findings: findings.values.sort_by { |row| [row[:result].to_s, row[:reason]] }
    }
  end

  def self.corpus(upstream, suite)
    observer = File.expand_path("regexp_parser_corpus.rb", __dir__)
    Dir.mktmpdir("flexr-regexp-parser") do |directory|
      path = File.join(directory, "requests")
      success = system({ "FLEXR_REGEXP_PARSER_CORPUS" => path, "FLEXR_REGEXP_PARSER_VERSION" => VERSION },
        RbConfig.ruby, "-S", "rspec", "-I", File.join(upstream, "spec"), "--require", observer, File.join(upstream, suite),
        chdir: directory, out: $stderr)
      abort "Upstream RSpec failed" unless success

      calls, requests = JSON.parse(File.read(path))
      cases = requests.map do |hex, encoding, flags, options|
        source = [hex].pack("H*").force_encoding(encoding)
        [flags.nil? ? source : Regexp.new(source, flags), options]
      end
      abort "Upstream RSpec did not exercise Regexp::Scanner" if cases.empty?

      [calls, cases]
    end
  end

  def self.compare(input, options)
    expected = reference(input, options)
    actual = begin
      Scanner.scan(input, options)
    rescue Unsupported => e
      e
    end
    if expected.is_a?(StandardError)
      outcome = actual.is_a?(Unsupported) ? "prototype rejected" : "prototype accepted"
      return [:upstream_error, "#{expected.class.name} (#{outcome})", { message: expected.message }]
    end
    return [:unsupported, actual.message] if actual.is_a?(Unsupported)

    index = [expected.size, actual.size].max.times.find do |i|
      expected[i] != actual[i] || expected[i][2].encoding != actual[i][2].encoding
    end
    return [:exact] if index.nil?

    [:token_mismatch, "first differing token", { index: index, upstream: expected[index], flexr: actual[index] }]
  end

  def self.reference(input, options)
    Regexp::Scanner.scan(input, options: options)
  rescue Regexp::Scanner::ScannerError, ArgumentError => e
    e
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby -Ilib benchmark/regexp_parser_parity.rb UPSTREAM_CHECKOUT [SPEC_PATH]" unless (1..2).cover?(ARGV.size)

  puts JSON.pretty_generate(RegexpParserParity.run(ARGV[0], suite: ARGV.fetch(1, "spec")))
end
