# frozen_string_literal: true

module Flexr
  module Source
    module Passthrough
      module_function

      def remove_spans(source, spans, insertion:, payload:)
        result = source.dup
        spans.sort_by(&:first).reverse_each do |start_offset, end_offset|
          result.slice!(start_offset...end_offset)
        end
        result.insert(insertion, payload)
        result
      end

      def indentation(source, offset)
        line_start = source.rindex("\n", offset - 1)
        source[(line_start ? line_start + 1 : 0)...offset].to_s[/\A[ \t]*/].to_s
      end
    end
  end
end
