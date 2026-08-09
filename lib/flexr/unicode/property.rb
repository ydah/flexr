# frozen_string_literal: true

module Flexr
  module Unicode
    VERSION = Data::VERSION

    module Property
      ALIASES = {
        "L" => "L", "Letter" => "L", "N" => "N", "Number" => "N", "Nd" => "Nd",
        "Hiragana" => "Hiragana", "Greek" => "Greek", "ASCII" => "ASCII",
        "Alnum" => "Alnum", "Word" => "Word", "Space" => "Space", "XDigit" => "XDigit",
        "Cntrl" => "Cntrl", "Lower" => "Lowercase", "Lowercase" => "Lowercase",
        "Upper" => "Uppercase", "Uppercase" => "Uppercase"
      }.freeze
      CACHE = {}
      module_function

      def ranges(name, negate: false)
        key = [name.to_s, negate]
        return CACHE[key] if CACHE.key?(key)

        canonical = ALIASES.fetch(name.to_s, name.to_s)
        ranges = Data::PROPERTIES.fetch(canonical) do
          raise CompileError, "unknown Unicode property: #{name}"
        end
        ranges = complement(ranges) if negate
        CACHE[key] = ranges.map(&:dup).freeze
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
