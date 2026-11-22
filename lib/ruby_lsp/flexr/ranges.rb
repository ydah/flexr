# frozen_string_literal: true

module RubyLsp
  module Flexr
    class Ranges
      def initialize(source, encoding)
        @source = source
        @encoding = encoding
        @line_starts = [0]
        offset = 0
        source.each_line do |line|
          offset += line.bytesize
          @line_starts << offset if line.end_with?("\n")
        end
      end

      def location(location)
        range(location.start_offset, location.end_offset)
      end

      def range(first, last)
        Interface::Range.new(start: position(first), end: position(last))
      end

      private

      def position(offset)
        offset = [offset, @source.bytesize].min
        line = (@line_starts.bsearch_index { |start| start > offset } || @line_starts.length) - 1
        column = @source.byteslice(@line_starts.fetch(line)...offset).delete_suffix("\r")
        character = case @encoding
        when Encoding::UTF_8 then column.bytesize
        when Encoding::UTF_16LE then column.encode(Encoding::UTF_16LE).bytesize / 2
        else column.length
        end
        Interface::Position.new(line: line, character: character)
      end
    end
  end
end
