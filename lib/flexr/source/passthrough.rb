# frozen_string_literal: true

module Flexr
  module Source
    module Passthrough
      ENCODING_COMMENT = /\A[ \t]*#.*(?:coding|encoding)\s*[:=]\s*[-A-Za-z0-9_]+/i
      FROZEN_COMMENT = /\A[ \t]*#\s*frozen_string_literal\s*:\s*(?:true|false)\b/i

      module_function

      def remove_spans(source, spans, insertion:, payload:)
        result = source.dup
        top_level = spans.reject do |span|
          spans.any? do |outer|
            next false if outer.equal?(span)

            outer.first <= span.first && span.last <= outer.last &&
              (outer.first < span.first || span.last < outer.last)
          end
        end
        removals = top_level.map do |start_offset, end_offset|
          start_offset = line_start_offset(source, start_offset) unless start_offset == insertion
          [start_offset, end_offset]
        end
        adjusted_insertion = insertion - removals.sum do |start_offset, end_offset|
          next 0 if start_offset >= insertion

          [end_offset, insertion].min - start_offset
        end
        removals.sort_by(&:first).reverse_each do |start_offset, end_offset|
          result.slice!(start_offset...end_offset)
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
    end
  end
end
