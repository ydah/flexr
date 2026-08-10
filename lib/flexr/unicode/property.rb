# frozen_string_literal: true

module Flexr
  module Unicode
    VERSION = Data::VERSION

    module Property
      ALIASES = {
        "L" => "L", "Letter" => "L", "N" => "N", "Number" => "N", "Nd" => "Nd",
        "Hiragana" => "Hiragana", "Greek" => "Greek", "ASCII" => "ASCII",
        "Any" => "Any", "Assigned" => "Assigned", "Cased_Letter" => "LC",
        "digit" => "Nd", "alpha" => "Alphabetic", "alnum" => "Alnum",
        "word" => "Word", "space" => "Space", "Alnum" => "Alnum", "Word" => "Word",
        "Space" => "Space", "XDigit" => "XDigit", "Cntrl" => "Cntrl",
        "Lower" => "Lowercase", "Lowercase" => "Lowercase",
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
        ranges = if canonical.start_with?("POSIX_")
          posix_ranges(canonical.delete_prefix("POSIX_"))
        else
          property_ranges(canonical, name)
        end
        ranges = complement(ranges) if negate
        CACHE[key] = ranges.map(&:dup).freeze
      end

      def canonical_name(name)
        raw = name.to_s.strip
        raw = raw.split("=", 2).last if raw.include?("=")
        normalized = normalize_name(raw)
        alias_entry = ALIASES.find { |candidate, _canonical| normalize_name(candidate) == normalized }
        return alias_entry.last if alias_entry

        Data::PROPERTIES.keys.find { |candidate| normalize_name(candidate) == normalized } || raw
      end

      def normalize_name(name)
        name.to_s.delete("-_ ").downcase
      end

      def property_ranges(canonical, original_name)
        case canonical
        when "Alnum"
          merge_ranges(Data::PROPERTIES.fetch("Alnum") + Data::PROPERTIES.fetch("Other_Alphabetic"))
        when "Word"
          merge_ranges(Data::PROPERTIES.fetch("Alnum") + Data::PROPERTIES.fetch("Other_Alphabetic") + [[0x5f, 0x5f]])
        else
          Data::PROPERTIES.fetch(canonical)
        end
      rescue KeyError
        raise CompileError, "unknown Unicode property: #{original_name}"
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

      def posix_ranges(name)
        alpha = Data::PROPERTIES.fetch("Alphabetic")
        case name
        when "alnum" then merge_ranges(Data::PROPERTIES.fetch("Alnum") + alpha)
        when "alpha" then alpha
        when "blank"
          [[0x09, 0x09], [0x20, 0x20], [0xa0, 0xa0], [0x1680, 0x1680],
           [0x2000, 0x200a], [0x202f, 0x202f], [0x205f, 0x205f], [0x3000, 0x3000]]
        when "cntrl" then Data::PROPERTIES.fetch("Cntrl")
        when "digit" then Data::PROPERTIES.fetch("Nd")
        when "graph" then complement(merge_ranges(Data::PROPERTIES.fetch("Space") + Data::PROPERTIES.fetch("Cntrl")))
        when "lower" then merge_ranges(Data::PROPERTIES.fetch("Ll") + Data::PROPERTIES.fetch("Lowercase"))
        when "print" then complement(Data::PROPERTIES.fetch("Cntrl"))
        when "punct" then Data::PROPERTIES.fetch("P")
        when "space" then Data::PROPERTIES.fetch("Space")
        when "upper" then merge_ranges(Data::PROPERTIES.fetch("Lu") + Data::PROPERTIES.fetch("Uppercase"))
        when "xdigit" then [[0x30, 0x39], [0x41, 0x46], [0x61, 0x66]]
        else raise CompileError, "unknown POSIX character class: #{name}"
        end
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
    end
  end
end
