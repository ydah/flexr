# frozen_string_literal: true

module Flexr
  module Runtime
    module ShortestMatch
      UTF8_ROWS = Automaton::UTF8.rows(Encoding::UTF_8).each(&:freeze).freeze unless const_defined?(:UTF8_ROWS, false)

      def scan(expected = nil)
        return super unless @config.options[:shortest_states]&.include?(@lexer.state)

        start = @lexer.byte_pos
        return unless @lexer.valid_utf8_at?(start)

        dfa = @compiled.machines.fetch(@lexer.state).dfa
        buffer = @lexer.buffer
        cursor = start
        state = @lexer.__flexr_dfa_start(dfa, start)
        utf8 = @config.encoding == Encoding::UTF_8
        scalar = 0
        tracker = @lexer.__send__(:__flexr_tagged_captures, dfa) if @lexer.respond_to?(:__flexr_tagged_captures, true)
        tags = tracker if tracker&.tracking?

        loop do
          if scalar.zero? && (cursor > start || @config.options[:allow_empty_match])
            match = shortest_acceptance(dfa.accepts[state], cursor, start, buffer, expected, tracker)
            return match if match
          end
          return unless buffer.ensure_available?(cursor + 1)

          byte = buffer.getbyte(cursor)
          @lexer.consume_step!
          state = transition(dfa, state, byte)
          return unless state
          scalar = UTF8_ROWS[scalar][byte] if utf8
          return unless scalar

          tags&.advance(byte, cursor)
          cursor += 1
          ensure_token_size!(cursor, start, rule: dfa.accepts[state].first&.rule_index)
        end
      end

      private

      def shortest_acceptance(acceptances, ending, start, buffer, expected, tracker)
        acceptances.each do |acceptance|
          next if acceptance.bol_only && !@lexer.beginning_of_line?
          next unless @lexer.utf8_boundary?(ending)

          rule = @rules.fetch(acceptance.rule_index)
          next if expected && !expected_rule?(rule, expected, buffer, start, ending)
          next unless acceptance.valid_end_at?(buffer, ending, @lexer, rule)

          trailing = shortest_trailing_length(rule, buffer, ending)
          next unless trailing

          ensure_token_size!(ending, start, rule: rule)
          match = reusable_match(rule, start, ending, ending + trailing)
          match.capture = rule.capture_patterns&.[](acceptance.pattern_index)
          tracker&.remember(acceptance, ending)
          @lexer.instance_variable_get(:@flexr_trace)&.select_shortest(match, expected)
          return tracker ? tracker.finish(match, buffer) : match
        end
        nil
      end

      def shortest_trailing_length(rule, buffer, start)
        return 0 unless rule.trailing
        return trailing_length(rule, buffer, start) if @config.encoding == Encoding::BINARY

        dfa = rule.trailing_dfa || trailing_dfa(rule.trailing)
        state = @lexer.__flexr_dfa_start(dfa, start)
        cursor = start
        scalar = 0
        longest = 0 if trailing_accept?(dfa, state, buffer, cursor, start, rule)
        while buffer.ensure_available?(cursor + 1)
          byte = buffer.getbyte(cursor)
          state = dfa.transition(state, byte)
          scalar = UTF8_ROWS[scalar][byte]
          break unless state && scalar

          cursor += 1
          @lexer.consume_step!
          size = cursor - start
          @lexer.ensure_lookahead_size!(size, rule: rule)
          longest = size if scalar.zero? && trailing_accept?(dfa, state, buffer, cursor, start, rule)
        end
        longest
      end

      module RecognizerPolicy
        def initialize(compiled, config, state)
          @shortest_match = config.options[:shortest_states]&.include?(state)
          @shortest_allows_empty = config.options[:allow_empty_match] if @shortest_match
          super
        end

        def match(input, offset)
          return super unless @shortest_match && input.is_a?(String) && offset.is_a?(Integer) && offset.between?(0, input.bytesize)
          return if offset == input.bytesize

          walk(@dfa, input, offset) do |rule, ending|
            next if ending == offset && !@shortest_allows_empty
            next unless shortest_boundary?(input, ending)

            trailer = @trailing[rule]
            next if trailer && !shortest_trailer?(trailer, input, ending)

            identity = @identities.fetch(rule)
            return block_given? ? yield(identity, ending) : [identity, ending]
          end
          nil
        end

        private

        def shortest_boundary?(input, ending)
          !@utf8 || !continuation?(input.getbyte(ending))
        end

        def shortest_trailer?(dfa, input, start)
          walk(dfa, input, start) { |_, ending| return true if shortest_boundary?(input, ending) }
          false
        end
      end
      private_constant :RecognizerPolicy

      Interpreter.prepend(self)
      Recognizer.prepend(RecognizerPolicy)
    end
  end
end
