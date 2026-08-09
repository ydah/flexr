# frozen_string_literal: true

module Flexr
  module Codegen
    module TablePacker
      module_function

      def pack(rows)
        base = []
        default = rows.map { |row| row.values.tally.max_by(&:last)&.first || -1 }
        next_table = []
        check = []
        rows.each_with_index do |row, state|
          base[state] = next_table.length
          row.each do |class_id, destination|
            index = next_table.length
            next_table[index] = destination
            check[index] = class_id
          end
        end
        { base: base.freeze, default: default.freeze, next: next_table.freeze, check: check.freeze }.freeze
      end
    end
  end
end
