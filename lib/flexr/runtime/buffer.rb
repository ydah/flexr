# frozen_string_literal: true

module Flexr
  module Runtime
    class Buffer
      DEFAULT_CHUNK_SIZE = 64 * 1024

      attr_reader :base_offset, :max_buffer_size

      def initialize(input, chunk_size: DEFAULT_CHUNK_SIZE, max_buffer_size: 64 * 1024 * 1024,
                     retain_input: true, filename: nil)
        raise ArgumentError, "chunk_size must be positive" unless chunk_size.to_i.positive?
        raise ArgumentError, "max_buffer_size must be non-negative" if max_buffer_size.to_i.negative?

        @chunk_size = chunk_size.to_i
        @max_buffer_size = max_buffer_size.to_i
        @retain_input = retain_input
        @filename = filename
        @base_offset = 0
        @window_start = 0
        @io = input.is_a?(String) ? nil : input
        raise ArgumentError, "input must be a String or IO" if @io && !@io.respond_to?(:read)

        @source = input.is_a?(String) ? input : String.new(encoding: Encoding::BINARY)
        @eof = @io.nil?
        ensure_buffer_size!(@source.bytesize)
      end

      def bytesize
        return @source.bytesize if @window_start.zero? && base_offset.zero?

        base_offset + retained_bytesize
      end

      def retained_bytesize
        @source.bytesize - @window_start
      end

      def source
        return @source if @window_start.zero?

        @source.byteslice(@window_start..).to_s
      end

      def stable_source
        @source if @retain_input && @window_start.zero? && base_offset.zero?
      end

      def getbyte(position)
        return @source.getbyte(position) if @window_start.zero? && base_offset.zero? && position < @source.bytesize

        ensure_available?(position + 1)
        @source.getbyte(storage_position(position))
      end

      def byteslice(range, length = nil)
        ensure_range(range, length)
        if @window_start.zero? && base_offset.zero?
          return length ? @source.byteslice(range, length) : @source.byteslice(range)
        end

        if length
          @source.byteslice(storage_position(range), length)
        else
          @source.byteslice(storage_range(range))
        end
      end

      def ensure_available?(end_position)
        return true if end_position <= bytesize
        return false if @eof

        while bytesize < end_position && !@eof
          chunk = read_chunk
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

      def eof_loaded?
        @eof
      end

      def eof?(position)
        !ensure_available?(position + 1)
      end

      def utf8_boundary?(position)
        return false if position < base_offset
        return true if position == base_offset
        return true unless ensure_available?(position)

        following = getbyte(position)
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

      def utf8_character_length(position)
        first = getbyte(position)
        return 0 unless first
        return 1 if first <= 0x7f

        length = if first <= 0xdf
          2
        elsif first <= 0xef
          3
        else
          4
        end
        valid_utf8_at?(position) ? length : 1
      end

      def discard_before(position)
        return if @retain_input || position <= base_offset

        ending = [position, bytesize].min
        removed = ending - base_offset
        @window_start += removed
        @base_offset = ending
        compact_storage!
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

      def storage_position(position)
        local = position - base_offset
        return @window_start + local unless local.negative?

        raise RangeError, "byte #{position} has been discarded from the streaming buffer"
      end

      def storage_range(range)
        return storage_position(range) unless range.is_a?(Range)

        ending = range.end
        Range.new(storage_position(range.begin), ending.nil? ? nil : storage_position(ending), range.exclude_end?)
      end

      def ensure_buffer_size!(size)
        return if size <= max_buffer_size

        raise BufferTooLargeError.new(filename: @filename, byte_pos: bytesize)
      end

      def read_chunk
        capacity = max_buffer_size - retained_bytesize
        if capacity.zero?
          probe = @io.read(1)
          if probe.nil? || probe.empty?
            @eof = true
            return nil
          end

          raise BufferTooLargeError.new(filename: @filename, byte_pos: bytesize)
        end

        @io.read([@chunk_size, capacity].min)
      end

      def compact_storage!
        return if @window_start.zero?

        if @window_start == @source.bytesize
          @source = String.new(encoding: @source.encoding)
          @window_start = 0
        elsif @window_start >= @chunk_size || @window_start * 2 >= @source.bytesize
          @source = @source.byteslice(@window_start..)
          @window_start = 0
        end
      end
    end
  end
end
