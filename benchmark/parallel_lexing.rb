# frozen_string_literal: true

require "json"
require_relative "../examples/toml/lexer.flexr"

lexer = TomlExample::Lexer
workers = Integer(ARGV.fetch(0, "4"), 10)
input = (0...32_000).map { |i| "field_#{i} = \"value #{i} UTF-8 é\" # note\n" }.join.freeze
expected = lexer.new(input).tokens
plan = Flexr::Runtime::ParallelPlan.new(lexer, input, workers: workers)

scans = {
  serial: -> { lexer.new(input).tokens },
  parallel: -> { lexer.parallel_tokens(input, workers: workers) }
}
scans.each_value { |scan| abort "warmup tokens differ" unless scan.call == expected }

samples = scans.transform_values { [] }
7.times do |iteration|
  scans.keys.rotate(iteration % scans.size).each do |name|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    tokens = scans.fetch(name).call
    samples.fetch(name) << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000)
    abort "tokens differ on run #{iteration + 1} of #{name}" unless tokens == expected
  end
end

milliseconds = samples.transform_values do |durations|
  sorted = durations.sort
  { min: sorted.first, median: sorted.fetch(sorted.size / 2), max: sorted.last }
end
puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, bytes: input.bytesize, tokens: expected.size, workers: plan.chunks.size,
                          certified_cuts: plan.chunks.drop(1).count(&:certified), milliseconds: milliseconds)
