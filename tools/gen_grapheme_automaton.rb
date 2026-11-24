# frozen_string_literal: true

require_relative "grapheme_regexp_source"
require_relative "../lib/flexr/unicode/utf8_splitter"

module GraphemeAutomatonGenerator
  DEFAULT = ["Other", nil, false].freeze
  CONTROL = %w[CR LF Control].freeze

  class ByteEncoder
    def initialize(classes)
      root = Array.new(256)
      classes.each_with_index do |ranges, symbol|
        ranges.each do |lo, hi|
          Flexr::Unicode::Utf8Splitter.split(lo, hi).each do |sequence|
            insert(root, sequence, 0, ~symbol)
          end
        end
      end
      @classifier_rows = []
      @classifier_root = intern_classifier(root, {})
    end

    def encode(scalar_rows)
      @rows = Array.new(scalar_rows.length)
      @ids = {}
      scalar_rows.each_with_index do |transitions, state|
        @rows[state] = project(@classifier_rows.fetch(@classifier_root), transitions, {})
      end

      raise "grapheme DFA exceeds the binary format" if @rows.length > 0xffff

      @rows.each_with_index.flat_map do |row, state|
        row.each_index.chunk { |byte| row.fetch(byte) }.flat_map do |target, bytes|
          target ? [state, bytes.first, bytes.last, target] : []
        end
      end
    end

    private

    def insert(row, sequence, index, symbol)
      lo, hi = sequence.fetch(index)
      if index == sequence.length - 1
        row.fill(symbol, lo..hi)
      else
        lo.upto(hi) { |byte| insert(row[byte] ||= Array.new(256), sequence, index + 1, symbol) }
      end
    end

    def intern_classifier(row, ids)
      key = row.map { |entry| entry.is_a?(Array) ? intern_classifier(entry, ids) : entry }
      ids[key] ||= @classifier_rows.push(key).length - 1
    end

    def project(row, transitions, memo)
      row.map do |entry|
        next if entry.nil?
        next transitions.fetch(~entry) if entry.negative?
        next memo.fetch(entry) if memo.key?(entry)

        continuation = project(@classifier_rows.fetch(entry), transitions, memo)
        memo[entry] = continuation.any? ? (@ids[continuation] ||= @rows.push(continuation).length - 1) : nil
      end
    end
  end

  module_function

  def properties(directory)
    events = Hash.new { |hash, codepoint| hash[codepoint] = {} }
    add_property(directory, events, "auxiliary/GraphemeBreakProperty.txt", 0) { |property, _| property }
    add_property(directory, events, "DerivedCoreProperties.txt", 1) { |property, value| value if property == "InCB" }
    add_property(directory, events, "emoji/emoji-data.txt", 2) { |property, _| true if property == "Extended_Pictographic" }

    symbols = {}
    current = DEFAULT.dup
    (events.keys | [0, 0xd800, 0xe000, 0x110000]).sort.each_cons(2) do |lo, next_start|
      events[lo].each { |index, value| current[index] = value }
      next if lo.between?(0xd800, 0xdfff)

      (symbols[current.dup] ||= []) << [lo, next_start - 1]
    end
    symbols
  end

  def add_property(directory, events, basename, index)
    File.foreach(File.join(directory, basename), encoding: "UTF-8") do |line|
      range, property, detail = line.split("#", 2).first.split(";").map(&:strip)
      next unless property

      value = yield(property, detail)
      next if value.nil?

      lo, hi = range.split("..").map { |codepoint| Integer(codepoint, 16) }
      events[lo][index] = value
      ending = events[(hi || lo) + 1]
      ending[index] = DEFAULT.fetch(index) unless ending.key?(index)
    end
  end

  def scalar_rows(alphabet)
    start = [nil, false, nil, nil]
    states = [start]
    ids = { start => 0 }
    states.map do |state|
      alphabet.map do |symbol|
        target = advance(state, symbol)
        target && (ids[target] ||= states.push(target).length - 1)
      end
    end
  end

  def minimize(rows)
    groups = [0] + ([1] * (rows.length - 1))
    loop do
      ids = {}
      refined = rows.each_with_index.map do |row, state|
        signature = [groups.fetch(state), row.map { |target| groups.fetch(target) unless target.nil? }]
        ids[signature] ||= ids.length
      end
      if refined == groups
        return groups.uniq.map do |group|
          rows.fetch(groups.index(group)).map { |target| groups.fetch(target) unless target.nil? }
        end
      end

      groups = refined
    end
  end

  def advance(state, symbol)
    previous, odd_regional_count, indic, emoji = state
    current, incb, pictograph = symbol
    joins = if previous.nil? || (previous == "CR" && current == "LF")
      true
    elsif CONTROL.include?(previous) || CONTROL.include?(current)
      false
    else
      (previous == "L" && %w[L V LV LVT].include?(current)) ||
        (%w[LV V].include?(previous) && %w[V T].include?(current)) ||
        (%w[LVT T].include?(previous) && current == "T") ||
        %w[Extend ZWJ SpacingMark].include?(current) ||
        previous == "Prepend" ||
        (indic == :linker && incb == "Consonant") ||
        (emoji == :zwj && pictograph) ||
        (odd_regional_count && current == "Regional_Indicator")
    end
    return unless joins

    [
      current,
      current == "Regional_Indicator" && !odd_regional_count,
      indic_state(indic, incb),
      emoji_state(emoji, current, pictograph)
    ]
  end

  def indic_state(indic, incb)
    return :consonant if incb == "Consonant"
    return unless indic

    case incb
    when "Extend" then indic
    when "Linker" then :linker
    end
  end

  def emoji_state(emoji, current, pictograph)
    return :pictograph if pictograph
    return unless emoji == :pictograph

    case current
    when "Extend" then :pictograph
    when "ZWJ" then :zwj
    end
  end

  def generate(directory)
    header = File.foreach(File.join(directory, "auxiliary/GraphemeBreakProperty.txt")).first
    version = header.to_s[/\A# GraphemeBreakProperty-(\d+\.\d+\.\d+)\.txt/, 1]
    raise ArgumentError, "GraphemeBreakProperty.txt does not identify its Unicode version" unless version

    properties = properties(directory)
    classes = properties.values
    rows = minimize(scalar_rows(properties.keys))
    edges = ByteEncoder.new(classes).encode(rows)
    encoded_edges = [edges.pack("v*")].pack("m")
    <<~RUBY
      # frozen_string_literal: true
      # shareable_constant_value: literal

      # Generated by tools/gen_grapheme_automaton.rb.

      module Flexr
        module Unicode
          module Data
            module GraphemeAutomaton
              UNICODE_VERSION = #{version.dump}
              CLASSES = [
      #{classes.map { |ranges| "          #{ranges.inspect}," }.join("\n")}
              ]
              SCALAR_COUNT = #{rows.length}
              REFERENCE_SOURCE = #{GraphemeRegexpSource.build(rows).dump}
              BYTE_EDGES = <<~BASE64.unpack1("m").freeze
      #{encoded_edges.each_line.map { |line| "          #{line}" }.join}
              BASE64
            end
          end
        end
      end
    RUBY
  end
end

if $PROGRAM_NAME == __FILE__
  directory = ARGV.fetch(0) { abort "Usage: ruby tools/gen_grapheme_automaton.rb UCD_DIRECTORY [OUTPUT]" }
  output = ARGV.fetch(1, File.expand_path("../lib/flexr/unicode/data/grapheme_automaton.rb", __dir__))
  File.write(output, GraphemeAutomatonGenerator.generate(directory))
end
