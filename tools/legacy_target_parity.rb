# frozen_string_literal: true

require "json"

def lexer_class(name)
  name.split("::").reduce(Object) { |scope, constant| scope.const_get(constant, false) }
end

def prepare(directory, target)
  require "fileutils"
  require_relative "../benchmark/run"

  {
    "json" => "JsonExample::Lexer", "toml" => "TomlExample::Lexer",
    "graphql" => "GraphqlExample::Lexer", "sql" => "SqlExample::Lexer",
    "ruby_subset" => "RubySubset::Lexer"
  }.each do |workload, name|
    specification = File.expand_path("../examples/#{workload}/lexer.flexr.rb", __dir__)
    input = Flexr::Benchmarking::DEFAULT_INPUTS.find { |pattern, _| pattern.match?(specification) }.last
    load specification
    output = File.join(directory, workload)
    FileUtils.mkdir_p(output)
    File.binwrite(File.join(output, "input"), input)
    File.binwrite(File.join(output, "expected.json"), JSON.generate(lexer_class(name).new(input).tokens))
    File.write(File.join(output, "class_name"), name)
    Flexr::Generator.new(specification, output: File.join(output, "lexer.rb"),
                        options: { standalone: true, target_ruby: target }).generate
  end
end

def verify(directory)
  load File.expand_path("lexer.rb", directory)
  name = File.read(File.join(directory, "class_name"))
  input = File.binread(File.join(directory, "input")).force_encoding(Encoding::UTF_8).freeze
  expected = JSON.parse(File.binread(File.join(directory, "expected.json")))
  actual = JSON.parse(JSON.generate(lexer_class(name).new(input).tokens))
  abort "#{name} token parity failed on #{RUBY_DESCRIPTION}" unless actual == expected

  puts "#{name} matched #{actual.length} tokens on Ruby #{RUBY_VERSION}"
end

case ARGV.fetch(0)
when "prepare" then prepare(ARGV.fetch(1), ARGV.fetch(2))
when "verify" then verify(ARGV.fetch(1))
else abort "expected prepare or verify"
end
