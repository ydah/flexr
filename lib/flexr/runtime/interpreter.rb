# frozen_string_literal: true

module Flexr
  module Runtime
    Match = Struct.new(:rule, :start_pos, :end_pos, :total_end_pos, keyword_init: true)

    class Interpreter
      def initialize(lexer)
        @lexer = lexer
      end

      def scan
        machine = @lexer.class.__flexr_compiled.machines.fetch(@lexer.state)
        data = @lexer.binary_input
        position = @lexer.byte_pos
        state = machine.dfa.start
        best = reference_match(position, data)
        cursor = position

        while cursor < data.bytesize
          byte = data.getbyte(cursor)
          state = machine.dfa.transition(state, byte)
          break unless state

          cursor += 1
          machine.dfa.accepts[state].each do |rule_index|
            candidate = @lexer.class.__flexr_rules.fetch(rule_index)
            next if candidate.bol_only && !@lexer.beginning_of_line?
            next unless candidate.end_anchor.nil? || end_anchor_match?(data, cursor)

            trailing_length = trailing_length(candidate, data, cursor)
            next if candidate.trailing && trailing_length.nil?

            total_end = cursor + (trailing_length || 0)
            next if best && total_end < best.total_end_pos
            next if best && total_end == best.total_end_pos && rule_index > best.rule.index

            best = Match.new(rule: candidate, start_pos: position, end_pos: cursor,
                             total_end_pos: total_end)
          end
        end
        best
      end

      private

      def reference_match(position, data)
        candidates = @lexer.class.__flexr_rules.filter_map do |rule|
          next unless rule.patterns.any? { |pattern| pattern.is_a?(::Regexp) && pattern.source.include?("\\p{") }
          next if rule.bol_only && !@lexer.beginning_of_line?

          match = rule.patterns.filter_map do |pattern|
            pattern.match(@lexer.input.byteslice(position..), 0)
          rescue ArgumentError
            nil
          end.max_by { |item| item[0].bytesize }
          next unless match && match.begin(0).zero?
          trailing = trailing_length(rule, data, position + match[0].bytesize)
          next if rule.trailing && trailing.nil?

          Match.new(rule: rule, start_pos: position, end_pos: position + match[0].bytesize,
                    total_end_pos: position + match[0].bytesize + (trailing || 0))
        end
        candidates.max_by { |candidate| [candidate.total_end_pos, -candidate.rule.index] }
      end

      def trailing_length(rule, data, position)
        return 0 unless rule.trailing

        regexp = rule.trailing
        segment = @lexer.input.byteslice(position..)
        match = regexp.match(segment, 0)
        return nil unless match && match.begin(0).zero?

        match[0].bytesize
      rescue ArgumentError
        nil
      end

      def end_anchor_match?(data, position)
        position == data.bytesize || data.getbyte(position) == 0x0a
      end
    end
  end
end
