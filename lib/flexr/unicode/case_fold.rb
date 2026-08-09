# frozen_string_literal: true

module Flexr
  module Unicode
    module CaseFold
      module_function

      def ranges(lo, hi)
        table = Data.const_defined?(:CASE_FOLD, false) ? Data::CASE_FOLD : {}
        equivalents = table.flat_map do |point, folded|
          [point, folded].grep(lo..hi)
        end
        if table.empty? && hi - lo <= 4096
          equivalents.concat((lo..hi).filter_map do |point|
            folded = point.chr(Encoding::UTF_8).swapcase.ord
            [point, folded] unless folded == point
          end.flatten)
        end
        merge([[lo, hi]] + equivalents.uniq.map { |point| [point, point] })
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
