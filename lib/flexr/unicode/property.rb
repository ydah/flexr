# frozen_string_literal: true

module Flexr
  module Unicode
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
        start = nil
        0.upto(0x10ffff) do |codepoint|
          matched = begin
            regexp.match?([codepoint].pack("U"))
          rescue RangeError, ArgumentError
            false
          end
          if matched && start.nil?
            start = codepoint
          elsif !matched && start
            ranges << [start, codepoint - 1]
            start = nil
          end
        end
        ranges << [start, 0x10ffff] if start
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
