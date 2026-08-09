# frozen_string_literal: true

require "benchmark"
require_relative "../lib/flexr"

source = File.read(File.expand_path("../examples/json/lexer.flexr.rb", __dir__))
input = '{"answer": 42}' * 10_000
runtime = nil
elapsed = Benchmark.realtime do
  load File.expand_path("../examples/json/lexer.flexr.rb", __dir__)
  runtime = ObjectSpace.each_object(Class).find { |klass| klass.name == "JsonExample::Lexer" }
  runtime.new(input).tokens
end
puts "runtime: #{(input.bytesize / elapsed / 1_000_000).round(3)} MB/s"
puts "source_bytes: #{source.bytesize}"
