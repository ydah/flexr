# frozen_string_literal: true

module Flexr
  module Unicode
    module CaseFold
      module_function

      def ranges(lo, hi)
        table = Data.const_defined?(:CASE_FOLD, false) ? Data::CASE_FOLD : {}
        return [[lo, hi]] if table.empty?

        points = {}
        table.each do |point, folded|
          next unless point.between?(lo, hi) || folded.between?(lo, hi)

          points[point] = true
          points[folded] = true
        end
        loop do
          changed = false
          table.each do |point, folded|
            next unless points.key?(point) || points.key?(folded)
            next if points.key?(point) && points.key?(folded)

            points[point] = true
            points[folded] = true
            changed = true
          end
          break unless changed
        end
        merge([[lo, hi]] + points.keys.map { |point| [point, point] })
      end

      def merge(ranges)
        ranges.sort_by(&:first).each_with_object([]) do |range, result|
          if result.empty? || range.first > result.last.last + 1
            result << range.dup
          else
            result.last[1] = [result.last.last, range.last].max
          end
        end
      end
    end
  end
end
