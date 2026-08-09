# frozen_string_literal: true

module Flexr
  module Unicode
    module Utf8Splitter
      module_function

      def split(lo, hi)
        raise ArgumentError, "invalid codepoint range" if lo > hi || lo.negative? || hi > 0x10ffff

        ranges = []
        [[0, 0x7f, 1], [0x80, 0x7ff, 2], [0x800, 0xffff, 3], [0x10000, 0x10ffff, 4]].each do |min, max, length|
          lower = [lo, min].max
          upper = [hi, max].min
          next if lower > upper

          walk(lower, upper, length, [], ranges)
        end
        ranges
      end

      def walk(lo, hi, length, prefix, output)
        if prefix.length == length
          output << prefix.map { |byte| [byte, byte] }
          return
        end

        first_byte = prefix.empty? ? encoded(lo)[0] : 0x80
        last_byte = prefix.empty? ? encoded(hi)[0] : 0xbf
        first_byte.upto(last_byte) do |byte|
          next_prefix = prefix + [byte]
          min_cp, max_cp = prefix_bounds(next_prefix, length)
          next if min_cp.nil? || max_cp < lo || min_cp > hi

          if lo <= min_cp && max_cp <= hi
            rest = length - next_prefix.length
            output << next_prefix.map { |value| [value, value] } + Array.new(rest) { [0x80, 0xbf] }
          else
            walk(lo, hi, length, next_prefix, output)
          end
        end
      end

      def encoded(codepoint)
        [codepoint].pack("U").bytes
      end

      def prefix_bounds(prefix, length)
        return [nil, nil] if prefix.empty?

        bytes = prefix + Array.new(length - prefix.length, 0x80)
        high = prefix + Array.new(length - prefix.length, 0xbf)
        if prefix.length == 1
          bytes[1] = 0xa0 if length == 3 && prefix.first == 0xe0
          high[1] = 0x9f if length == 3 && prefix.first == 0xed
          bytes[1] = 0x90 if length == 4 && prefix.first == 0xf0
          high[1] = 0x8f if length == 4 && prefix.first == 0xf4
        end
        return [nil, nil] unless valid_prefix?(bytes, length) && valid_prefix?(high, length)

        [decode(bytes), decode(high)]
      end

      def valid_prefix?(bytes, length)
        first = bytes.first
        expected = if first <= 0x7f then 1 elsif first.between?(0xc2, 0xdf) then 2
                   elsif first.between?(0xe0, 0xef) then 3
                   elsif first.between?(0xf0, 0xf4) then 4 end
        return false unless expected == length
        return false if bytes[1..].any? { |byte| !byte.between?(0x80, 0xbf) }
        return false if length == 3 && first == 0xe0 && bytes[1] < 0xa0
        return false if length == 3 && first == 0xed && bytes[1] > 0x9f
        return false if length == 4 && first == 0xf0 && bytes[1] < 0x90
        return false if length == 4 && first == 0xf4 && bytes[1] > 0x8f
        true
      end

      def decode(bytes)
        return bytes.first if bytes.length == 1
        value = case bytes.length
        when 2 then ((bytes[0] & 0x1f) << 6) | (bytes[1] & 0x3f)
        when 3 then ((bytes[0] & 0x0f) << 12) | ((bytes[1] & 0x3f) << 6) | (bytes[2] & 0x3f)
        when 4 then ((bytes[0] & 0x07) << 18) | ((bytes[1] & 0x3f) << 12) |
          ((bytes[2] & 0x3f) << 6) | (bytes[3] & 0x3f)
        end
        value
      end
    end
  end
end
