# frozen_string_literal: true

module Flexr
  module Unicode
    VERSION = "15.1.0"

    module Property
      CACHE = {}
      module_function

      def ranges(name, negate: false)
        key = [name, negate]
        return CACHE[key] if CACHE.key?(key)

        regexp = property_regexp(name)
        ranges = codepoint_ranges(regexp)
        ranges = complement(ranges) if negate
        CACHE[key] = ranges.freeze
      end

      def property_regexp(name)
        normalized = name.to_s
        normalized = normalized[0] if normalized.length == 1
        normalized = {
          "L" => "L", "Letter" => "L", "N" => "N", "Number" => "N",
          "Nd" => "Nd", "Hiragana" => "Hiragana", "Greek" => "Greek",
          "ASCII" => "ASCII", "Alnum" => "Alnum", "Word" => "Word",
          "Space" => "Space", "XDigit" => "XDigit", "Cntrl" => "Cntrl",
          "Lower" => "Lowercase", "Upper" => "Uppercase"
        }.fetch(normalized, normalized)
        ::Regexp.new("\\p{#{normalized}}")
      rescue RegexpError
        raise CompileError, "unknown Unicode property: #{name}"
      end

      def codepoint_ranges(regexp)
        ranges = []
        scanner = ::Regexp.new("(?:#{regexp.source})+")
        [[0, 0xd7ff], [0xe000, 0x10ffff]].each do |lower, upper|
          segment = (lower..upper).to_a.pack("U*")
          segment.scan(scanner) do
            match = ::Regexp.last_match
            range_start = lower + match.begin(0)
            ranges << [range_start, range_start + match[0].length - 1]
          end
        end
        ranges
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
