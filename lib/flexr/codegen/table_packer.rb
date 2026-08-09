# frozen_string_literal: true

module Flexr
  module Codegen
    module TablePacker
      module_function

      def pack(rows)
        base = []
        default = rows.map { |row| row.tally.max_by { |_value, count| count }&.first }
        next_table = []
        check = []
        occupied = {}
        rows.each_with_index do |row, state|
          entries = row.each_index.reject { |class_id| row[class_id] == default[state] }
          offset = 0
          while entries.any? { |class_id| occupied.key?(offset + class_id) }
            offset += 1
          end
          base[state] = offset
          entries.each do |class_id|
            index = offset + class_id
            next_table[index] = row[class_id]
            check[index] = class_id
            occupied[index] = true
          end
        end
        { base: base.freeze, default: default.freeze, next: next_table.freeze, check: check.freeze }.freeze
      end
    end
  end
end
