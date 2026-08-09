# frozen_string_literal: true

module Flexr
  module Runtime
    class Buffer
      attr_reader :source

      def initialize(input, chunk_size: 64 * 1024)
        @source = input.is_a?(String) ? input : input.read
        @chunk_size = chunk_size
      end

      def bytesize
        source.bytesize
      end

      def getbyte(position)
        source.getbyte(position)
      end

      def byteslice(range, length = nil)
        length ? source.byteslice(range, length) : source.byteslice(range)
      end
    end
  end
end
