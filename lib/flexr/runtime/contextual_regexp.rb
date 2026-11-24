# frozen_string_literal: true

module Flexr
  module Runtime
    class ContextualRegexp < Data.define(:regexp, :invalid_eof, :instructions, :entry, :left_context,
                                         :history_bytes, :invalid_left, :invalid_both, :capture_names)
      def initialize(regexp:, instructions:, entry:, invalid_eof: nil, left_context: false, history_bytes: nil,
                     invalid_left: nil, invalid_both: nil, capture_names: nil)
        super(regexp: regexp.freeze, invalid_eof: invalid_eof&.freeze,
              instructions: instructions.each(&:freeze).freeze, entry: entry, left_context: left_context,
              history_bytes: history_bytes, invalid_left: invalid_left&.freeze, invalid_both: invalid_both&.freeze,
              capture_names: capture_names&.each(&:freeze)&.freeze)
      end

      def match(lexer, rule, starting, ending: nil)
        cursor = Cursor.new(lexer, rule, starting, ending, instructions)
        return unless cursor.walk(entry, starting, ending)

        subject = cursor.subject
        reference = (invalid_eof if cursor.invalid_end?) || regexp
        prefix = ""
        if history_bytes
          prefix, invalid_prefix = cursor.left_prefix(history_bytes)
          reference = (invalid_both if cursor.invalid_end?) || invalid_left if invalid_prefix
          # The rejected byte occupies a source position that Ruby can see but cannot consume.
          subject << "\0" if cursor.invalid_end? && invalid_eof
        elsif left_context && starting.positive?
          # One marker reproduces the start and line anchors of a sliced subject.
          prefix = lexer.beginning_of_line? ? "\n" : " "
        end
        subject = prefix + subject unless prefix.empty?
        origin = prefix.length
        if ending
          offset = prefix.bytesize + ending - starting
          # Constrain Ruby's ordered capture replay to the endpoint chosen by the DFA.
          suffix_size = subject.byteslice(offset..).length
          groups, remainder = suffix_size.divmod(10_000)
          suffix = (".{10000}" * groups) + ".{#{remainder}}"
          reference = ::Regexp.new("#{reference.source}(?=(?m:#{suffix})\\z)", reference.options)
        end
        match = reference.match(subject, origin)
        capture_names && match ? CapturedMatch.new(match, capture_names) : match
      end

      CapturedMatch = Data.define(:match, :names) do
        def [](index) = match[index]
        def byteoffset(name) = match.byteoffset(name)

        def named_captures(symbolize_names: false)
          keys = symbolize_names ? names.map(&:to_sym) : names
          match.named_captures(symbolize_names: symbolize_names).slice(*keys)
        end
      end
      private_constant :CapturedMatch

      class Cursor
        def initialize(lexer, rule, starting, ending, instructions)
          @lexer = lexer
          @buffer = lexer.buffer
          @rule = rule
          @starting = starting
          @ending = ending
          @instructions = instructions
          @utf8 = lexer.utf8_input?
          @loaded_to = ending || starting
        end

        AssertionInput = Data.define(:cursor, :origin) do
          def getbyte(position)
            cursor.read(position, origin, raw: true)
          end
        end

        def invalid_end?
          @terminal == :invalid
        end

        def subject
          @buffer.byteslice(@starting, @loaded_to - @starting).force_encoding(@utf8 ? Encoding::UTF_8 : Encoding::BINARY)
        end

        def left_prefix(bytes)
          prefix = @buffer.left_bytes_at(@starting, bytes).force_encoding(@utf8 ? Encoding::UTF_8 : Encoding::BINARY)
          return [prefix, false] if prefix.valid_encoding?

          suffix = String.new(encoding: Encoding::UTF_8)
          prefix.each_char do |char|
            if char.valid_encoding?
              suffix << char
            else
              suffix.clear
            end
          end
          [" #{suffix}", true]
        end

        def walk(entry, starting, ending, assertion_origin = nil)
          pending = [[entry, starting, nil]]
          seen = {}
          until pending.empty?
            address, position, loop_position = pending.pop
            while address
              key = [address, position, loop_position]
              break if seen[key]

              seen[key] = true
              kind, first, second, following = @instructions.fetch(address)
              case kind
              when :accept
                return position if !ending || position == ending

                break
              when :byte
                break if ending && position == ending

                byte = read(position, assertion_origin)
                break unless byte&.between?(first, second)

                position += 1
                address = following
              when :choice
                pending << [second, position, loop_position]
                address = first
              when :lookahead
                break unless walk(first, position, nil, assertion_origin || position)

                address = second
              when :predicate
                input = AssertionInput.new(cursor: self, origin: assertion_origin || position)
                break unless first.valid_end_at?(input, position)

                address = second
              when :context_predicate
                input = AssertionInput.new(cursor: self, origin: assertion_origin || position)
                context = if following
                  @buffer.left_state_at(following, position)
                else
                  at_line_start = @lexer.__flexr_beginning_of_line_at?(position, @starting)
                  Automaton::LeftContext.at(position, at_line_start)
                end
                break unless first.fetch(context)&.valid_end_at?(input, position)

                address = second
              when :left_anchor
                if first == :source_start
                  break unless position.zero?
                elsif position.positive?
                  break unless @lexer.__flexr_beginning_of_line_at?(position, @starting)
                  break unless read(position, assertion_origin || position, raw: true)
                end
                address = second
              when :span
                input = AssertionInput.new(cursor: self, origin: assertion_origin)
                append_span_ends(pending, first, input, second, position, ending, loop_position)
                break
              when :not_lf
                break if read(position, assertion_origin || position) == 0x0a

                address = first
              when :loop
                pending << [second, position, loop_position]
                loop_position = [position, loop_position].freeze
                address = first
              when :loop_end
                entered_at, loop_position = loop_position
                address = position == entered_at ? second : first
              end
            end
          end
          nil
        end

        def read(position, assertion_origin, raw: false)
          if position >= @loaded_to && !@terminal
            byte = @buffer.getbyte(position)
            if byte && (!@utf8 || @buffer.valid_utf8_at?(position))
              @loaded_to = position + (@utf8 ? @buffer.utf8_character_length(position) : 1)
            else
              @terminal = byte ? :invalid : :eof
            end
          end
          return if position >= @loaded_to && !(raw && invalid_end?)

          byte = @buffer.getbyte(position)
          return unless byte

          @lexer.consume_step!
          if assertion_origin
            from = @ending ? [assertion_origin, @ending].max : assertion_origin
            @lexer.ensure_lookahead_size!(position - from + 1, rule: @rule)
          end
          byte
        end

        private

        def append_span_ends(pending, dfa, input, following, position, ending, loop_position)
          state = @lexer.__flexr_dfa_start(dfa, position, @starting)
          loop do
            accepted = dfa.accepts.fetch(state).any? do |label|
              next true unless label.end_anchor

              boundary = input.origin ? input : AssertionInput.new(cursor: self, origin: position)
              label.valid_end_at?(boundary, position)
            end
            pending << [following, position, loop_position] if accepted
            break if ending == position

            byte = input.getbyte(position)
            break unless byte && (state = dfa.transition(state, byte))

            position += 1
          end
        end
      end
      private_constant :Cursor
    end
  end
end
