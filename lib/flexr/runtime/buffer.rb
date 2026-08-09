# frozen_string_literal: true

module Flexr
  module Runtime
    class Buffer
      DEFAULT_CHUNK_SIZE = 64 * 1024

      attr_reader :source

      def initialize(input, chunk_size: DEFAULT_CHUNK_SIZE)
        raise ArgumentError, "chunk_size must be positive" unless chunk_size.to_i.positive?

        @chunk_size = chunk_size.to_i
        @io = input.is_a?(String) ? nil : input
        raise ArgumentError, "input must be a String or IO" if @io && !@io.respond_to?(:read)

        @source = input.is_a?(String) ? input : String.new(encoding: Encoding::BINARY)
        @eof = @io.nil?
      end

      def bytesize
        source.bytesize
      end

      def getbyte(position)
        ensure_available?(position + 1)
        source.getbyte(position)
      end

      def byteslice(range, length = nil)
        ensure_range(range, length)
        length ? source.byteslice(range, length) : source.byteslice(range)
      end

      def ensure_available?(end_position)
        return true if end_position <= bytesize
        return false if @eof

        while bytesize < end_position && !@eof
          chunk = @io.read(@chunk_size)
          if chunk.nil? || chunk.empty?
            @eof = true
            break
          end

          @source.force_encoding(chunk.encoding) if @source.empty?
          @source << chunk
        end
        bytesize >= end_position
      end

      def read_to_end
        ensure_available?(Float::INFINITY)
        source
      end

      def eof?(position)
        !ensure_available?(position + 1)
      end

      def utf8_boundary?(position)
        return false if position.negative?
        return true if position.zero?
        return true unless ensure_available?(position)

        following = source.getbyte(position)
        following.nil? || (following & 0xc0) != 0x80
      end

      def valid_utf8_at?(position)
        first = getbyte(position)
        return false unless first
        return true if first <= 0x7f

        length = if first.between?(0xc2, 0xdf)
          2
        elsif first.between?(0xe0, 0xef)
          3
        elsif first.between?(0xf0, 0xf4)
          4
        end
        return false unless length
        return false unless ensure_available?(position + length)

        byteslice(position, length).dup.force_encoding(Encoding::UTF_8).valid_encoding?
      end

      private

      def ensure_range(range, length)
        if length
          ensure_available?(range + length)
          return
        end

        unless range.is_a?(Range)
          ensure_available?(range + 1)
          return
        end

        return read_to_end if range.end.nil?

        ending = range.end + (range.exclude_end? ? 0 : 1)
        ensure_available?(ending)
      end
    end
  end
end
