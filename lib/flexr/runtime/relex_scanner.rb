# frozen_string_literal: true

module Flexr
  module Runtime
    class RelexScanner
      class TrackingInterpreter < Interpreter
        private

        def acceleration_enabled? = false
      end

      module ReadWindow
        attr_accessor :read_end

        def track_reads
          @read_end = 0
          @source_end = bytesize
        end

        def record_read(ending)
          ending = @source_end + 1 if ending > @source_end
          @read_end = ending if ending > @read_end
        end

        def getbyte(position)
          # Tagged trailing can decide a match at EOF without probing past the last byte.
          ending = position.negative? || position >= @source_end - 1 ? @source_end + 1 : position + 1
          record_read(ending)
          super
        end

        def ensure_available?(ending)
          record_read(ending)
          super
        end

        def eof_loaded?
          eof = super
          record_read(@source_end + 1) if eof
          eof
        end

        def scan_source = nil

        def stable_source = nil

        def tagged_trailing_input? = @eof && @source.instance_of?(String) && @source.singleton_methods.empty?
      end

      module Cursor
        LAYOUT_FIELDS = %i[
          @__flexr_indent_levels @__flexr_indent_brackets @__flexr_indent_candidate @__flexr_indent_counting
        ].freeze
        private_constant :LAYOUT_FIELDS

        def __flexr_relex_track
          @buffer.extend(ReadWindow)
          @buffer.track_reads
          @generated_scanner = false
          @interpreter = TrackingInterpreter.new(self)
        end

        def __flexr_relex_boundary
          return if @pending || @active_rule || @halted || @more_start || @more_requested ||
                    @__flexr_input_frames || @__flexr_pending_inputs || @__flexr_delegated_queue&.any? ||
                    @__flexr_leading_trivia&.any? || @__flexr_indent_queue&.any? ||
                    !@non_progress_signatures.empty? || !@eof_fired_states.empty?

          dfa = self.class.__flexr_compiled.machines.fetch(@state).dfa
          left_context = @buffer.relex_left_context(@position) if @buffer.respond_to?(:relex_left_context)
          Boundary.new(position: @position, line: @line, column: @column, state: @state, stack: @state_stack.dup.freeze,
                       dfa_start: __flexr_dfa_start(dfa, @position), bol: @bol, left_context: left_context,
                       layout: relex_layout)
        end

        def __flexr_relex_restore(boundary)
          @position = @match_start = @match_end = @text_start = boundary.position
          @line = @text_line = boundary.line
          @column = @text_column = boundary.column
          @bol = boundary.bol
          @state = boundary.state
          @state_stack = boundary.stack.dup
          @buffer.restore_relex_left_context(@position, boundary.left_context.first) if boundary.left_context
          boundary.layout&.zip(LAYOUT_FIELDS)&.each do |value, field|
            instance_variable_set(field, copy_cursor_value(value, freeze_copy: false))
          end
        end

        private

        def relex_layout
          return unless @__flexr_indentation

          brackets = @__flexr_indent_brackets.map { |bracket| bracket.dup.freeze }.freeze
          [@__flexr_indent_levels.dup.freeze, brackets, @__flexr_indent_candidate, @__flexr_indent_counting].freeze
        end
      end

      module ObservedEOF
        private

        def eof?
          @buffer.record_read(@position + 1)
          super
        end
      end

      private_constant :TrackingInterpreter, :ReadWindow, :Cursor, :ObservedEOF

      def initialize(lexer_class, input, filename:, error_mode:, track_reads: true)
        lexer_class.compile!
        @lexer = lexer_class.new(input, filename: filename, error_mode: error_mode)
        @lexer.extend(Cursor)
        return unless track_reads

        @lexer.extend(ObservedEOF)
        @lexer.__flexr_relex_track
      end

      def next_token = @lexer.next_token

      def boundary = @lexer.__flexr_relex_boundary

      def position = @lexer.byte_pos

      def read_end = @lexer.buffer.read_end

      def restore(boundary, read_end: nil)
        @lexer.__flexr_relex_restore(boundary)
        @lexer.buffer.read_end = read_end if read_end
        self
      end

      def start_at(position, line:, column:)
        bol = position.zero? || @lexer.buffer.getbyte(position - 1) == 0x0a
        restore(boundary.with(position: position, line: line, column: column, bol: bol, left_context: nil))
        boundary
      end
    end
  end
end
