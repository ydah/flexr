# frozen_string_literal: true

module Flexr
  module Source
    module Passthrough
      ENCODING_COMMENT = /\A[ \t]*#.*(?:coding|encoding)\s*[:=]\s*[-A-Za-z0-9_]+/i
      FROZEN_COMMENT = /\A[ \t]*#\s*frozen_string_literal\s*:\s*(?:true|false)\b/i

      module_function

      def remove_spans(source, spans, insertion:, payload:)
        rewrite(source, spans.map { |start_offset, end_offset| [start_offset, end_offset, ""] },
                insertion: insertion, payload: payload)
      end

      def rewrite(source, edits, insertion:, payload:)
        result = source.dup
        normalized_edits = edits.map do |start_offset, end_offset, replacement|
          start_offset = line_start_offset(source, start_offset) if replacement.empty? && start_offset != insertion
          [start_offset, end_offset, replacement]
        end
        validate_non_overlapping!(normalized_edits)
        adjusted_insertion = insertion + normalized_edits.sum do |start_offset, end_offset, replacement|
          next 0 if start_offset >= insertion

          replaced_size = [end_offset, insertion].min - start_offset
          replacement.bytesize - replaced_size
        end
        normalized_edits.sort_by(&:first).reverse_each do |start_offset, end_offset, replacement|
          result[start_offset...end_offset] = replacement
        end
        result.insert(adjusted_insertion, payload)
        result
      end

      def insert_after_preamble(source, payload)
        offset = 0
        line, next_offset = next_line(source, offset)
        if line&.start_with?("#!")
          offset = next_offset
          line, next_offset = next_line(source, offset)
        end

        while line && magic_comment?(line)
          offset = next_offset
          line, next_offset = next_line(source, offset)
        end

        source.dup.insert(offset, payload)
      end

      def indentation(source, offset)
        line_start = source.rindex("\n", offset - 1)
        source[(line_start ? line_start + 1 : 0)...offset].to_s[/\A[ \t]*/].to_s
      end

      def line_start_offset(source, offset)
        line_start = source.rindex("\n", offset - 1) unless offset.zero?
        line_start = line_start ? line_start + 1 : 0
        prefix = source.byteslice(line_start...offset)
        prefix&.match?(/\A[ \t]*\z/) ? line_start : offset
      end

      def next_line(source, offset)
        return [nil, offset] if offset >= source.bytesize

        ending = source.index("\n", offset)
        ending ? [source.byteslice(offset..ending), ending + 1] : [source.byteslice(offset..), source.bytesize]
      end

      def magic_comment?(line)
        ENCODING_COMMENT.match?(line) || FROZEN_COMMENT.match?(line)
      end

      def validate_non_overlapping!(edits)
        edits.sort_by(&:first).each_cons(2) do |left, right|
          next if left[1] <= right[0]

          raise ArgumentError, "overlapping source edits"
        end
      end
    end
  end
end
