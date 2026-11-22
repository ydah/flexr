# frozen_string_literal: true

module Flexr
  module Runtime
    class Checkpoint
      def initialize(owner, lexer_id, state)
        @owner = owner
        @lexer_id = lexer_id
        @state = state.freeze
        freeze
      end

      private_class_method :new

      def inspect = "#<#{self.class}>"

      def __flexr_state(owner, lexer_id)
        return @state if @owner.equal?(owner) && @lexer_id == lexer_id

        raise ArgumentError, "checkpoint belongs to a different lexer"
      end
    end

    CHECKPOINT_FIELDS = %i[
      @position @line @column @bol @state @state_stack @pending @matched @match_start @match_end
      @text_start @text_line @text_column @more_start @more_line @more_column @more_requested
      @non_progress_signatures @active_rule @eof_fired_states @halted @__flexr_leading_trivia
      @__flexr_indent_levels @__flexr_indent_brackets @__flexr_indent_queue @__flexr_indent_candidate @__flexr_indent_counting
    ].freeze
    private_constant :CHECKPOINT_FIELDS

    def checkpoint
      @__flexr_checkpoint_owner ||= Object.new.freeze
      state = CHECKPOINT_FIELDS.to_h do |field|
        [field, copy_cursor_value(instance_variable_get(field))]
      end
      Checkpoint.send(:new, @__flexr_checkpoint_owner, object_id, state)
    end

    def restore(checkpoint)
      raise ArgumentError, "expected a lexer checkpoint" unless checkpoint.instance_of?(Checkpoint)

      state = checkpoint.__flexr_state(@__flexr_checkpoint_owner, object_id)
      check_cursor_range!(state[:@more_start] || state.fetch(:@position))
      check_cursor_range!(state.fetch(:@position))
      state.each { |field, value| instance_variable_set(field, copy_cursor_value(value, freeze_copy: false)) }
      self
    end

    def seek(position)
      raise ArgumentError, "byte position must be an Integer" unless position.is_a?(Integer)

      check_cursor_range!(position)
      raise ArgumentError, "seek must end at a UTF-8 codepoint boundary" unless seek_boundary?(position)

      starting, line, column = seek_origin(position)
      bytes = @buffer.byteslice(starting, position - starting).force_encoding(Encoding::BINARY)
      if (newline = bytes.rindex("\n"))
        line += bytes.count("\n")
        column = 1
        bytes = bytes.byteslice((newline + 1)..)
      end
      bytes.force_encoding(Encoding::UTF_8) if utf8_input?
      column += bytes.length

      @position = @match_start = @match_end = @text_start = position
      @line = @text_line = line
      @column = @text_column = column
      @bol = column == 1
      @matched = @pending = @active_rule = nil
      @__flexr_leading_trivia = nil if defined?(@__flexr_leading_trivia)
      @more_requested = @halted = false
      finalize_more
      @eof_fired_states.clear
      @non_progress_signatures.clear
      discard_consumed_input! unless @retain_input
      self
    end

    private

    def copy_cursor_value(value, freeze_copy: true)
      return value unless value.is_a?(Array) || value.is_a?(Hash) || value.is_a?(String)

      copy = value.dup
      freeze_copy ? copy.freeze : copy
    end

    def check_cursor_range!(position)
      raise RangeError, "byte #{position} is outside the buffered input" unless position.between?(0, @buffer.bytesize)
      raise RangeError, "byte #{position} has been discarded from the streaming buffer" if position < @buffer.base_offset
    end

    def seek_origin(position)
      return [@position, @line, @column] if position >= @position
      return [0, 1, 1] if @buffer.base_offset.zero?
      return [@more_start, @more_line, @more_column] if @more_start && position >= @more_start

      raise RangeError, "the coordinates of byte #{position} are no longer retained"
    end

    def seek_boundary?(position)
      return true unless utf8_input? && position.positive?
      return (@buffer.getbyte(position) & 0xc0) != 0x80 if position < @buffer.bytesize
      return true if @buffer.eof_loaded? || position == @buffer.base_offset

      start = position - 1
      start -= 1 while start > @buffer.base_offset && position - start < 4 && (@buffer.getbyte(start) & 0xc0) == 0x80
      @buffer.byteslice(start, position - start).force_encoding(Encoding::UTF_8).valid_encoding?
    end
  end
end
