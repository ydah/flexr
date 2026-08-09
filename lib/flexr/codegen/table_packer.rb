# frozen_string_literal: true

module Flexr
  module Codegen
    module TablePacker
      module_function

      def pack(rows, compression: :rows)
        full = compression.to_sym == :full
        base = []
        default = rows.map { |row| row.tally.max_by { |_value, count| count }&.first }
        fallback = full ? Array.new(rows.length) : nil
        next_table = []
        check = []
        occupied = {}
        rows.each_with_index do |row, state|
          if full
            candidate, matches = rows.each_index.take(state).map do |other_state|
              [other_state, row.each_index.count { |class_id| row[class_id] == rows[other_state][class_id] }]
            end.max_by(&:last)
            fallback[state] = candidate if candidate && matches > row.count { |value| value == default[state] }
          end
          inherited = fallback && fallback[state] ? rows.fetch(fallback.fetch(state)) : nil
          entries = row.each_index.reject do |class_id|
            row[class_id] == (inherited ? inherited[class_id] : default[state])
          end
          offset = 0
          while entries.any? { |class_id| occupied.key?(offset + class_id) }
            offset += 1
          end
          base[state] = offset
          entries.each do |class_id|
            index = offset + class_id
            next_table[index] = row[class_id]
            check[index] = state
            occupied[index] = true
          end
        end
        result = { base: base.freeze, default: default.freeze, next: next_table.freeze, check: check.freeze }
        result[:fallback] = fallback.freeze if fallback
        result.freeze
      end

      def encode(packed)
        result = {
          encoding: :base64,
          base: encode_array(packed.fetch(:base)),
          default: encode_array(packed.fetch(:default), nil_value: -1),
          next: encode_array(packed.fetch(:next), nil_value: -1),
          check: encode_array(packed.fetch(:check), nil_value: -1)
        }
        result[:fallback] = encode_array(packed.fetch(:fallback), nil_value: -1) if packed[:fallback]
        result.freeze
      end

      def encode_array(values, nil_value: 0)
        [values.map { |value| value.nil? ? nil_value : value }.pack("l<*")].pack("m0")
      end
    end
  end
end
