# frozen_string_literal: true

module Flexr
  module Runtime
    Edit = Data.define(:start_byte, :end_byte, :replacement) do
      def initialize(start_byte:, end_byte:, replacement:)
        raise ArgumentError, "an edit requires integer byte offsets and a String replacement" unless
          start_byte.is_a?(Integer) && end_byte.is_a?(Integer) && replacement.is_a?(String)

        super(start_byte: start_byte, end_byte: end_byte, replacement: String.new(replacement).freeze)
      end
    end

    class Incremental
      Entry = Data.define(:boundary, :token_index, :read_end)
      private_constant :Entry

      attr_reader :input, :tokens

      def initialize(lexer_class, input, filename: nil, error_mode: :raise, pure_actions: false, previous: nil, edit: nil)
        raise ArgumentError, "incremental input must be a String" unless input.is_a?(String)
        raise ArgumentError, "filename must be a String" unless filename.nil? || filename.is_a?(String)
        raise ArgumentError, "pure_actions must be true or false" unless true.equal?(pure_actions) || false.equal?(pure_actions)

        @lexer_class = lexer_class
        @options = { filename: filename && String.new(filename).freeze, error_mode: error_mode }.freeze
        @pure_actions = pure_actions
        @input = String.new(input).freeze
        ensure_encoding!(@input)
        @tokens, @entries = scan(previous, edit) if reusable_rules? && (!previous || previous.entries)
        @tokens ||= @lexer_class.new(@input, **@options).tokens.map { |token| snapshot_token(token) || token }
        @tokens.freeze
        @entries&.freeze
        freeze
      end

      def relex(edit)
        raise ArgumentError, "expected a Flexr::Runtime::Edit" unless edit.instance_of?(Edit)

        first, last, replacement = edit.deconstruct
        raise ArgumentError, "edit byte range is outside the input" unless first.between?(0, last) && last <= @input.bytesize
        raise ArgumentError, "edit byte offsets must be on UTF-8 character boundaries" if
          utf8? && (!utf8_boundary?(first) || !utf8_boundary?(last))
        ensure_encoding!(replacement)
        bytes = @input.b
        return self if @entries && bytes.byteslice(first...last) == replacement.b && reusable_rules?

        updated = bytes.byteslice(0, first) + replacement.b + bytes.byteslice(last..)
        self.class.new(@lexer_class, updated.force_encoding(@input.encoding), **@options,
                       pure_actions: @pure_actions, previous: self, edit: edit)
      end

      protected

      attr_reader :entries

      private

      def utf8?
        @lexer_class.__flexr_config.encoding == Encoding::UTF_8
      end

      def ensure_encoding!(string)
        return unless utf8? && !string.b.force_encoding(Encoding::UTF_8).valid_encoding?

        raise ArgumentError, "incremental input and replacements must be valid UTF-8"
      end

      def utf8_boundary?(position)
        byte = @input.getbyte(position)
        !byte || (byte & 0xc0) != 0x80
      end

      def reusable_rules?
        spec = @lexer_class.__flexr_spec
        spec.eof_rules.empty? && !spec.options[:input_stack] && Boundary.standard_lexer?(@lexer_class) &&
          (@pure_actions || spec.rules.all? { |rule| rule.emit? || rule.skip? })
      end

      def scan(previous, edit)
        scanner = RelexScanner.new(@lexer_class, @input, **@options)
        tokens, entries = previous ? restart(previous, edit, scanner) : [[], []]
        delta = edit.replacement.bytesize - (edit.end_byte - edit.start_byte) if previous

        loop do
          if (boundary = scanner.boundary)
            entry = Entry.new(boundary, tokens.size, scanner.read_end)
            entries << entry unless entries.last == entry
            if previous && boundary.position >= edit.end_byte + delta &&
                (index = join_index(previous.entries, boundary, delta))
              splice_suffix(previous, index, entry, tokens, entries)
              break
            end
          end
          token = scanner.next_token
          break unless token

          token = snapshot_token(token)
          return unless token

          tokens << token
        end
        [tokens, entries]
      end

      def restart(previous, edit, scanner)
        first_affected = previous.entries.bsearch_index do |entry|
          entry.boundary.position > edit.start_byte || entry.read_end > edit.start_byte
        end
        entries = previous.entries.take(first_affected || previous.entries.size)
        return [[], []] if entries.empty?

        anchor = entries.last
        scanner.restore(anchor.boundary, read_end: anchor.read_end)
        [previous.tokens.take(anchor.token_index), entries]
      end

      def join_index(entries, boundary, delta)
        position = boundary.position - delta
        index = entries.bsearch_index { |entry| entry.boundary.position >= position }
        while index && (old = entries[index]) && old.boundary.position == position
          return index if boundary.converges?(old.boundary, delta: delta)

          index += 1
        end
        nil
      end

      def splice_suffix(previous, index, to, tokens, entries)
        from = previous.entries.fetch(index)
        source = from.boundary
        target = to.boundary
        delta = target.position - source.position
        line_delta = target.line - source.line
        column_delta = target.column - source.column
        suffix = previous.tokens.drop(from.token_index)
        suffix.map! { |token| move_token(token, delta, line_delta, column_delta, source.line) } unless
          delta.zero? && line_delta.zero? && column_delta.zero?
        tokens.concat(suffix)

        previous.entries.drop(index + 1).each do |entry|
          boundary = entry.boundary
          moved = boundary.with(position: boundary.position + delta, line: boundary.line + line_delta,
                                column: offset_column(boundary.column, boundary.line, source.line, column_delta))
          entries << Entry.new(moved, to.token_index + entry.token_index - from.token_index,
                               [to.read_end, entry.read_end + delta].max)
        end
      end

      def move_token(token, delta, line_delta, column_delta, join_line)
        return token unless token.is_a?(Token)

        location = token.location
        changes = {}
        if location
          moved = location.with(
            byte_begin: location.byte_begin + delta, byte_end: location.byte_end + delta,
            line_begin: location.line_begin + line_delta, line_end: location.line_end + line_delta,
            column_begin: offset_column(location.column_begin, location.line_begin, join_line, column_delta),
            column_end: offset_column(location.column_end, location.line_end, join_line, column_delta)
          )
          changes[:location] = moved unless moved == location
        end
        unless token.leading_trivia.empty?
          trivia = token.leading_trivia.map { |item| move_token(item, delta, line_delta, column_delta, join_line) }
          changes[:leading_trivia] = trivia unless trivia == token.leading_trivia
        end
        changes.empty? ? token : token.with(**changes)
      end

      def offset_column(column, line, join_line, delta)
        line == join_line ? column + delta : column
      end

      def snapshot_token(token)
        case token
        when Array
          return unless token.instance_of?(Array) && token.size == 2 && token.all? { |value| reusable_value?(value) }

          token.map { |value| snapshot_value(value) }.freeze
        when Token
          values = [token.type, token.value]
          return unless values.all? { |value| reusable_value?(value) }

          changes = { type: snapshot_value(token.type), value: snapshot_value(token.value) }
          unless token.leading_trivia.empty?
            trivia = token.leading_trivia.map { |item| snapshot_token(item) }
            return if trivia.any?(&:nil?)

            changes[:leading_trivia] = trivia
          end
          token.with(**changes)
        end
      end

      def reusable_value?(value)
        case value
        when String then value.instance_of?(String)
        when Symbol, Integer, Float, NilClass, TrueClass, FalseClass then true
        else false
        end
      end

      def snapshot_value(value)
        value.is_a?(String) ? String.new(value).freeze : value
      end
    end
  end
end
