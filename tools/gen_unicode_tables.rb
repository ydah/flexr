#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate compact property range files from an explicitly selected UCD
# checkout. The generated snapshot is used at runtime; host Regexp data is
# only used by this build-time tool.

input = ARGV.fetch(0) { abort "usage: gen_unicode_tables.rb UCD_DIRECTORY OUTPUT" }
output = ARGV.fetch(1) { abort "usage: gen_unicode_tables.rb UCD_DIRECTORY OUTPUT" }
version = File.read(File.join(input, "ReadMe.txt"))[/(?:Version|version)\s+([0-9.]+)/, 1] || "unknown"
File.write(File.join(output, "UNICODE_VERSION"), "#{version}\n")

properties = {
  "L" => "L", "Letter" => "L", "N" => "N", "Number" => "N", "Nd" => "Nd",
  "Hiragana" => "Hiragana", "Greek" => "Greek", "ASCII" => "ASCII",
  "Alnum" => "Alnum", "Word" => "Word", "Space" => "Space", "XDigit" => "XDigit",
  "Cntrl" => "Cntrl", "Lowercase" => "Lowercase", "Uppercase" => "Uppercase"
}

ranges_for = lambda do |name|
  regexp = Regexp.new("\\p{#{name}}")
  scanner = Regexp.new("(?:#{regexp.source})+")
  ranges = []
  [[0, 0xd7ff], [0xe000, 0x10ffff]].each do |lower, upper|
    segment = (lower..upper).to_a.pack("U*")
    segment.scan(scanner) do
      match = Regexp.last_match
      first = lower + match.begin(0)
      ranges << [first, first + match[0].length - 1]
    end
  end
  ranges
end

table = properties.to_h { |key, value| [key, ranges_for.call(value)] }
source = <<~RUBY
  # frozen_string_literal: true

  module Flexr
    module Unicode
      module Data
        VERSION = #{version.inspect}
        PROPERTIES = #{table.inspect}.freeze
      end
    end
  end
RUBY
File.write(File.join(output, "properties.rb"), source)
puts "Unicode #{version}: generated #{table.length} property tables"
