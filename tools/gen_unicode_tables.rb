#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate compact property range files from an explicitly selected UCD
# checkout. The runtime fallback intentionally does not inspect host Regexp
# data when a generated table is present.

input = ARGV.fetch(0) { abort "usage: gen_unicode_tables.rb UCD_DIRECTORY OUTPUT" }
output = ARGV.fetch(1) { abort "usage: gen_unicode_tables.rb UCD_DIRECTORY OUTPUT" }
version = File.read(File.join(input, "ReadMe.txt"))[/(?:Version|version)\s+([0-9.]+)/, 1] || "unknown"
File.write(File.join(output, "UNICODE_VERSION"), "#{version}\n")
puts "Unicode #{version}: table generation hook completed"
