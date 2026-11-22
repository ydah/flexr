# frozen_string_literal: true

module Flexr
  module Runtime
    def scan_until(delimiter)
      scan_delimiter(delimiter, full_line: false)
    end

    def scan_until_line(delimiter)
      scan_delimiter(delimiter, full_line: true)
    end

    private

    def scan_delimiter(delimiter, full_line:)
      raise ArgumentError, "delimiter scanning requires a matched rule action" unless @active_rule
      raise ArgumentError, "delimiter must be a nonempty String" unless delimiter.is_a?(String) && !delimiter.empty?

      delimiter = delimiter.b
      raise ArgumentError, "line delimiter must be free of newline bytes" if
        full_line && (delimiter.include?("\n") || delimiter.include?("\r"))
      raise ArgumentError, "delimiter must be valid UTF-8" if
        utf8_input? && !delimiter.dup.force_encoding(Encoding::UTF_8).valid_encoding?

      size = delimiter.bytesize
      fallbacks = delimiter_fallbacks(delimiter, size)
      guarded = scan_steps_guarded?
      cursor = @position
      matched = 0
      while (byte = @buffer.getbyte(cursor))
        consume_step! if guarded
        matched = advance_delimiter_prefix(delimiter, fallbacks, matched, byte)
        cursor += 1
        ensure_delimiter_extent!(cursor)
        next unless matched == size

        starting = cursor - size
        ending = delimiter_end(starting, cursor, full_line: full_line)
        if ending
          ensure_delimiter_extent!(ending)
          consume_step!(ending - cursor) if guarded && ending > cursor
          body = @buffer.byteslice(@position, starting - @position)
          @position = @match_end = ending
          @matched = nil
          return body
        end
        matched = fallbacks.fetch(matched - 1)
      end
      nil
    end

    def delimiter_fallbacks(delimiter, size)
      fallbacks = Array.new(size, 0)
      matched = 0
      (1...size).each do |index|
        matched = advance_delimiter_prefix(delimiter, fallbacks, matched, delimiter.getbyte(index))
        fallbacks[index] = matched
      end
      fallbacks
    end

    def advance_delimiter_prefix(delimiter, fallbacks, matched, byte)
      matched = fallbacks.fetch(matched - 1) while matched.positive? && delimiter.getbyte(matched) != byte
      matched += 1 if delimiter.getbyte(matched) == byte
      matched
    end

    def delimiter_end(starting, ending, full_line:)
      unless full_line
        return ending if utf8_boundary?(starting) && utf8_boundary?(ending)

        return
      end
      return unless __flexr_beginning_of_line_at?(starting, @match_start)

      case @buffer.getbyte(ending)
      when nil then ending
      when 0x0a then ending + 1
      when 0x0d then ending + 2 if @buffer.getbyte(ending + 1) == 0x0a
      end
    end

    def ensure_delimiter_extent!(ending)
      return if ending - @text_start <= @max_token_size

      raise TokenTooLargeError.new(filename: @filename, byte_pos: @text_start, line: @text_line, rule: @active_rule)
    end
  end
end
