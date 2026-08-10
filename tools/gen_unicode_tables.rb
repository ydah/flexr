#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate the vendored Unicode snapshot from the Unicode Character Database.
# This tool intentionally never asks the host Ruby Regexp implementation for
# a property set: changing the Ruby version must not change generated output.

require "fileutils"

input = ARGV.fetch(0) { abort "usage: gen_unicode_tables.rb UCD_DIRECTORY OUTPUT_DIRECTORY" }
output = ARGV.fetch(1) { abort "usage: gen_unicode_tables.rb UCD_DIRECTORY OUTPUT_DIRECTORY" }
FileUtils.mkdir_p(output)

def parse_ranges(path, property: nil)
  ranges = []
  File.foreach(path, encoding: "UTF-8") do |line|
    body, _comment = line.split("#", 2)
    fields = body.strip.split(";").map(&:strip)
    next if fields.empty? || fields.first.empty?
    next if property && fields[1] != property

    first, last = fields.first.split("..", 2).map { |value| Integer(value, 16) }
    last ||= first
    ranges << [first, last]
  end
  merge_ranges(ranges)
end

def merge_ranges(ranges)
  ranges.sort_by(&:first).each_with_object([]) do |range, merged|
    if merged.empty? || range.first > merged.last.last + 1
      merged << range.dup
    else
      merged.last[1] = [merged.last.last, range.last].max
    end
  end
end

def unicode_version(input)
  readme = File.join(input, "ReadMe.txt")
  text = File.file?(readme) ? File.read(readme) : ""
  text[/Version[- ]([0-9]+\.[0-9]+\.[0-9]+)/, 1] ||
    text[/Unicode\s+([0-9]+\.[0-9]+\.[0-9]+)/i, 1] || "unknown"
end

def category_ranges(path, categories)
  unicode_data_ranges(path, categories: Array(categories))
end

def unicode_data_ranges(path, categories: nil)
  selected_categories = categories && Array(categories)
  ranges = []
  first = last = nil
  current_category = nil
  File.foreach(path, encoding: "UTF-8") do |line|
    body = line.split("#", 2).first
    fields = body.strip.split(";")
    next if fields.length < 3

    codepoint = Integer(fields[0], 16)
    name = fields[1]
    category = fields[2]
    if name.end_with?(", First>")
      first = codepoint
      current_category = category
    elsif name.end_with?(", Last>") && first
      last = codepoint
      ranges << [first, last] if selected_categories.nil? || selected_categories.include?(current_category)
      first = last = current_category = nil
    elsif selected_categories.nil? || selected_categories.include?(category)
      ranges << [codepoint, codepoint]
    end
  end
  merge_ranges(ranges)
end

def property_file_ranges(path, names)
  names = Array(names)
  selected = []
  File.foreach(path, encoding: "UTF-8") do |line|
    body = line.split("#", 2).first
    fields = body.strip.split(";").map(&:strip)
    next if fields.length < 2 || !names.include?(fields[1])

    first, last = fields.first.split("..", 2).map { |value| Integer(value, 16) }
    last ||= first
    selected << [first, last]
  end
  merge_ranges(selected)
end

def property_names(path)
  names = {}
  File.foreach(path, encoding: "UTF-8") do |line|
    body = line.split("#", 2).first
    fields = body.strip.split(";").map(&:strip)
    names[fields[1]] = true if fields.length >= 2 && !fields[1].empty?
  end
  names.keys.sort
end

def complement_ranges(ranges, maximum: 0x10ffff)
  result = []
  cursor = 0
  ranges.each do |first, last|
    result << [cursor, first - 1] if cursor < first
    cursor = [cursor, last + 1].max
  end
  result << [cursor, maximum] if cursor <= maximum
  result
end

def case_fold_table(path)
  table = {}
  File.foreach(path, encoding: "UTF-8") do |line|
    body = line.split("#", 2).first
    fields = body.strip.split(";").map(&:strip)
    next unless fields.length >= 3 && %w[C S].include?(fields[1])

    mapping = fields[2].split.map { |value| Integer(value, 16) }
    table[Integer(fields[0], 16)] = mapping.first if mapping.length == 1
  end
  table
end

unicode_data = File.join(input, "UnicodeData.txt")
scripts = File.join(input, "Scripts.txt")
prop_list = File.join(input, "PropList.txt")
case_folding = File.join(input, "CaseFolding.txt")
[unicode_data, scripts, prop_list, case_folding].each do |path|
  abort "missing UCD file: #{path}" unless File.file?(path)
end

properties = {
  "L" => category_ranges(unicode_data, %w[Lu Ll Lt Lm Lo]),
  "Letter" => category_ranges(unicode_data, %w[Lu Ll Lt Lm Lo]),
  "N" => category_ranges(unicode_data, %w[Nd Nl No]),
  "Number" => category_ranges(unicode_data, %w[Nd Nl No]),
  "Nd" => category_ranges(unicode_data, ["Nd"]),
  "ASCII" => [[0, 0x7f]],
  "Alphabetic" => merge_ranges(category_ranges(unicode_data, %w[Lu Ll Lt Lm Lo Nl]) +
                                 property_file_ranges(prop_list, ["Other_Alphabetic"])),
  "Other_Alphabetic" => property_file_ranges(prop_list, ["Other_Alphabetic"]),
  "Alnum" => merge_ranges(category_ranges(unicode_data, %w[Lu Ll Lt Lm Lo Nd Nl No]) +
                           property_file_ranges(prop_list, ["Other_Alphabetic"])),
  "Word" => merge_ranges(category_ranges(unicode_data, %w[Lu Ll Lt Lm Lo Nd Nl No]) +
                          property_file_ranges(prop_list, ["Other_Alphabetic"]) + [[0x5f, 0x5f]]),
  "Space" => property_file_ranges(prop_list, ["White_Space"]),
  "XDigit" => [[0x30, 0x39], [0x41, 0x46], [0x61, 0x66]],
  "Cntrl" => [[0, 0x1f], [0x7f, 0x9f]],
  "Lowercase" => merge_ranges(category_ranges(unicode_data, ["Ll"]) +
                               property_file_ranges(prop_list, ["Other_Lowercase"])),
  "Uppercase" => merge_ranges(category_ranges(unicode_data, ["Lu"]) +
                               property_file_ranges(prop_list, ["Other_Uppercase"]))
}
%w[Cc Cf Cn Co Cs Ll Lm Lo Lt Lu Mc Me Mn Nd Nl No Pc Pd Pe Pf Pi Po Ps Sc Sk Sm So Zl Zp Zs].each do |category|
  properties[category] = category_ranges(unicode_data, [category])
end
properties["Cn"] = complement_ranges(unicode_data_ranges(unicode_data))
{
  "C" => %w[Cc Cf Cn Co Cs], "M" => %w[Mc Me Mn], "P" => %w[Pc Pd Pe Pf Pi Po Ps],
  "S" => %w[Sc Sk Sm So], "Z" => %w[Zl Zp Zs], "LC" => %w[Lt Lu Ll]
}.each do |name, categories|
  properties[name] = category_ranges(unicode_data, categories)
end
properties["C"] = merge_ranges(properties.fetch("C") + properties.fetch("Cn"))

property_names(scripts).each do |script|
  properties[script] = property_file_ranges(scripts, [script])
end
properties["Any"] = [[0, 0x10ffff]]
properties["Assigned"] = complement_ranges(properties.fetch("Cn"))

version = unicode_version(input)
File.write(File.join(output, "UNICODE_VERSION"), "#{version}\n")
source = <<~RUBY
  # frozen_string_literal: true

  module Flexr
    module Unicode
      module Data
        VERSION = #{version.inspect}
        PROPERTIES = #{properties.inspect}.freeze
      end
    end
  end
RUBY
File.write(File.join(output, "properties.rb"), source)

fold_source = <<~RUBY
  # frozen_string_literal: true

  module Flexr
    module Unicode
      module Data
        CASE_FOLD = #{case_fold_table(case_folding).inspect}.freeze
      end
    end
  end
RUBY
File.write(File.join(output, "case_folding.rb"), fold_source)
puts "Unicode #{version}: generated #{properties.length} property tables"
