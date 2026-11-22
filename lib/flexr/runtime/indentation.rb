# frozen_string_literal: true

module Flexr
  module Runtime
    module Indentation
      def self.configuration(newline: nil, indent: nil, dedent: nil, brackets: [], tab_width: 8)
        types = [newline, indent, dedent]
        validate!(types.all?(Symbol) && types.uniq.length == 3, "requires distinct newline, indent, and dedent Symbols")
        validate!(tab_width.is_a?(Integer) && tab_width.positive?, "tab_width must be a positive Integer")
        validate!(brackets.is_a?(Array) && brackets.all? { |pair| pair.is_a?(String) && pair.valid_encoding? && pair.length == 2 },
                  "brackets must be an Array of two-character strings")
        characters = brackets.flat_map(&:chars).map(&:b)
        validate!(characters.uniq.length == characters.length, "bracket characters must be distinct")
        { newline: newline, indent: indent, dedent: dedent, brackets: brackets.map { |pair| pair.dup.freeze }.freeze,
          tab_width: tab_width }.freeze
      end

      def self.validate!(condition, message)
        return if condition

        message = "indentation #{message}"
        diagnostic = Diagnostics.error("FLEXR-E018", message)
        raise CompileError.new(message, diagnostic: diagnostic)
      end
      private_class_method :validate!

      def initialize(...)
        super
        @__flexr_indentation = self.class.__flexr_config.options[:indentation]
        return unless @__flexr_indentation

        @__flexr_indent_pairs = @__flexr_indentation.fetch(:brackets).to_h { |pair| pair.chars.map(&:b) }
        @__flexr_indent_bracket_lexemes = @__flexr_indent_pairs.keys + @__flexr_indent_pairs.values
        @__flexr_indent_bracket_lengths = @__flexr_indent_bracket_lexemes.map(&:bytesize).uniq
        reset_indentation
      end

      def next_token(expect: nil)
        return expect.nil? ? super() : super(expect: expect) unless @__flexr_indentation

        expect = Configuration.expected_tokens!(expect) + [@__flexr_indentation.fetch(:newline)] unless expect.nil?
        return @__flexr_indent_queue.shift unless @__flexr_indent_queue.empty?

        loop do
          @__flexr_indent_bracket = @__flexr_indent_newline_width = nil
          token = expect.nil? ? super() : super(expect: expect)
          unless token
            finish_indentation
            return @__flexr_indent_queue.shift
          end
          return token if @__flexr_token_channel

          if token[0] == @__flexr_indentation.fetch(:newline)
            blank = !@__flexr_indent_candidate.nil?
            @__flexr_indent_candidate = @__flexr_indent_newline_width || 0
            @__flexr_indent_counting = true
            if blank || !@__flexr_indent_brackets.empty?
              trivia = token.leading_trivia if token.respond_to?(:leading_trivia)
              @__flexr_leading_trivia = trivia.dup if trivia && !trivia.empty?
              next
            end

            return token
          end

          if @match_start == @position && @match_end == @position && eof?
            finish_indentation
          else
            adjust_indentation(token) if @__flexr_indent_candidate && @__flexr_indent_brackets.empty?
            @__flexr_indent_candidate = nil
            track_indentation_bracket
          end
          return token if @__flexr_indent_queue.empty?

          @__flexr_indent_queue << token
          return @__flexr_indent_queue.shift
        end
      end

      def __flexr_layout_candidate?(expected, starting, ending)
        return true if @__flexr_indent_candidate && @__flexr_indent_brackets.empty? &&
          (expected.key?(@__flexr_indentation.fetch(:indent)) || expected.key?(@__flexr_indentation.fetch(:dedent)))

        return false if @__flexr_indent_bracket_lexemes.empty?

        starting = @more_start || starting
        if ending
          return false unless @__flexr_indent_bracket_lengths.include?(ending - starting)

          @__flexr_indent_bracket_lexemes.include?(@buffer.byteslice(starting...ending).b)
        else
          byte = @buffer.getbyte(starting)
          @__flexr_indent_bracket_lexemes.any? { |lexeme| lexeme.getbyte(0) == byte }
        end
      end

      def seek(position)
        return super unless @__flexr_indentation
        raise ArgumentError, "indentation lexers can seek only to byte 0; use a checkpoint to restore another offset" if position != 0

        super
        reset_indentation
        self
      end

      private

      def reset_indentation
        @__flexr_indent_levels = [0]
        @__flexr_indent_brackets = []
        @__flexr_indent_queue = []
        @__flexr_indent_candidate = 0
        @__flexr_indent_counting = true
      end

      def execute(rule)
        super
        return unless @__flexr_indentation

        @__flexr_indent_candidate, @__flexr_indent_counting = indentation_width(@match_start, @match_end, @__flexr_indent_candidate) if
          @__flexr_indent_candidate && @__flexr_indent_counting
        @__flexr_indent_bracket = nil
        return unless @pending && !@__flexr_token_channel

        if @pending[0] == @__flexr_indentation.fetch(:newline)
          @__flexr_indent_newline_width = indentation_after_newline
        elsif @__flexr_indent_bracket_lengths.include?(@match_end - @text_start)
          @__flexr_indent_bracket = @buffer.byteslice(@text_start, @match_end - @text_start).b
        end
      end

      def indentation_width(starting, ending, width = 0)
        tab_width = @__flexr_indentation.fetch(:tab_width)
        while starting < ending
          case @buffer.getbyte(starting)
          when 0x20 then width += 1
          when 0x09 then width += tab_width - (width % tab_width)
          else break
          end
          starting += 1
        end
        [width, starting == ending]
      end

      def indentation_after_newline
        starting = @match_end
        while starting > @match_start
          byte = @buffer.getbyte(starting - 1)
          break unless [0x20, 0x09].include?(byte)

          starting -= 1
        end
        indentation_width(starting, @match_end).first if starting > @match_start && @buffer.getbyte(starting - 1) == 0x0a
      end

      def adjust_indentation(token)
        width = @__flexr_indent_candidate
        return if width == @__flexr_indent_levels.last

        if width > @__flexr_indent_levels.last
          @__flexr_indent_levels << width
          @__flexr_indent_queue << indentation_token(:indent, token)
        else
          level = @__flexr_indent_levels.rindex(width)
          unless level
            raise LexError.new("indentation width #{width} does not match any earlier indentation level",
                               filename: @filename, byte_pos: @text_start, line: @text_line)
          end
          emit_indentation_dedents(level, token)
        end
      end

      def finish_indentation
        emit_indentation_dedents(0)
      end

      def emit_indentation_dedents(level, token = nil)
        while @__flexr_indent_levels.length > level + 1
          @__flexr_indent_levels.pop
          @__flexr_indent_queue << indentation_token(:dedent, token)
        end
      end

      def indentation_token(kind, token)
        type = @__flexr_indentation.fetch(kind)
        return [type, nil] unless @token_kind == :struct

        location = token&.location
        filename = location ? location.filename : @filename
        position = location ? location.byte_begin : @position
        line = location ? location.line_begin : @line
        column = location ? location.column_begin : @column
        point = Location.new(filename: filename, byte_begin: position, byte_end: position,
                             line_begin: line, line_end: line, column_begin: column, column_end: column)
        Token.new(type: type, value: nil, location: point)
      end

      def track_indentation_bracket
        bracket = @__flexr_indent_bracket
        return unless bracket

        if (closing = @__flexr_indent_pairs[bracket])
          @__flexr_indent_brackets << closing
        elsif @__flexr_indent_brackets.last == bracket
          @__flexr_indent_brackets.pop
        end
      end
    end
  end

  module DSL
    def indentation(newline:, indent:, dedent:, brackets: [], tab_width: 8)
      __flexr_mutate! do
        @__flexr_config.options[:indentation] = Runtime::Indentation.configuration(
          newline: newline, indent: indent, dedent: dedent, brackets: brackets, tab_width: tab_width
        )
        prepend Runtime::Indentation unless ancestors.include?(Runtime::Indentation)
      end
      nil
    end
  end
end
