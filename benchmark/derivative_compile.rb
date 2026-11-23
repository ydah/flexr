# frozen_string_literal: true

require "json"
require "flexr"

samples = Integer(ARGV.fetch(0, "7"), 10)
abort "pass an odd sample count of at least three" unless samples >= 3 && samples.odd?

root = File.expand_path("..", __dir__)
fixtures = %w[json toml graphql sql ruby_subset].to_h do |name|
  path = File.join(root, "examples", name, "lexer.flexr.rb")
  [name, [path, File.binread(path).gsub(/\r\n?/, "\n").force_encoding(Encoding::UTF_8)]]
end
fixtures["unicode_identifier"] = ["unicode_identifier.flexr.rb", <<~'SOURCE']
  class UnicodeIdentifier < Flexr::Lexer
    rule(/\p{L}[\p{L}\p{N}_]*/, emit: :IDENT)
  end
SOURCE

Flexr.cache_dir = nil
workloads = fixtures.transform_values do |(path, source)|
  generator = Flexr::Generator.new(path)
  timings = { subset: [], derivative: [] }
  compile = lambda do |construction|
    parsed = Flexr::Source::PrismReader.new(source, path: path).read
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    generator.send(:compile_parsed, parsed, construction: construction)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end
  timings.each_key { |construction| compile.call(construction) }
  samples.times do |index|
    order = index.even? ? timings.keys : timings.keys.reverse
    order.each { |construction| timings.fetch(construction) << compile.call(construction) }
  end
  timings.transform_values { |seconds| seconds.sort.fetch(samples / 2) }
end

puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, samples: samples, seconds: workloads)
