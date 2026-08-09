# frozen_string_literal: true

module Flexr
  module Unicode
    module CaseFold
      module_function

      def ranges(lo, hi)
        points = (lo..hi).to_a
        points.concat(points.filter_map do |point|
          folded = point.chr(Encoding::UTF_8).swapcase.ord
          folded == point ? nil : folded
        end)
        points.sort.uniq
      end
    end
  end
end
