# frozen_string_literal: true

module Flexr
  module Unicode
    VERSION = Data::VERSION

    module Property
      ALIASES = {
        "L" => "L", "Letter" => "L", "N" => "N", "Number" => "N", "Nd" => "Nd",
        "Hiragana" => "Hiragana", "Greek" => "Greek", "ASCII" => "ASCII",
        "Any" => "Any", "Assigned" => "Assigned", "Cased_Letter" => "LC",
        "Alnum" => "Alnum", "Word" => "Word", "Space" => "Space", "XDigit" => "XDigit",
        "Cntrl" => "Cntrl", "Lower" => "Lowercase", "Lowercase" => "Lowercase",
        "Upper" => "Uppercase", "Uppercase" => "Uppercase"
      }.freeze
      # rubocop:disable Style/MutableConstant
      CACHE = {}
      # rubocop:enable Style/MutableConstant
      module_function

      def ranges(name, negate: false)
        key = [name.to_s, negate]
        return CACHE[key] if CACHE.key?(key)

        canonical = canonical_name(name)
        ranges = Data::PROPERTIES.fetch(canonical) do
          raise CompileError, "unknown Unicode property: #{name}"
        end
        ranges = complement(ranges) if negate
        CACHE[key] = ranges.map(&:dup).freeze
      end

      def canonical_name(name)
        raw = name.to_s.strip
        raw = raw.split("=", 2).last if raw.include?("=")
        return ALIASES.fetch(raw) if ALIASES.key?(raw)

        compact = raw.delete("-_ ")
        Data::PROPERTIES.keys.find { |candidate| candidate.delete("-_ ") == compact } || raw
      end

      def complement(ranges)
        result = []
        cursor = 0
        ranges.each do |lo, hi|
          result << [cursor, lo - 1] if cursor < lo
          cursor = hi + 1
        end
        result << [cursor, 0x10ffff] if cursor <= 0x10ffff
        result
      end
    end
  end
end
