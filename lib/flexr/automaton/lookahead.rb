# frozen_string_literal: true

module Flexr
  module Automaton
    Lookahead = Data.define(:transitions, :eof, :ec) do
      def initialize(transitions:, eof:, ec:)
        super(transitions: transitions.each(&:freeze).freeze, eof: eof.freeze, ec: ec.freeze)
      end

      def match?(input, cursor)
        state = 0
        loop do
          row = transitions.fetch(state)
          return row unless row.is_a?(Array)

          byte = input.getbyte(cursor)
          return eof.fetch(state) unless byte

          yield cursor if block_given?
          state = row.fetch(ec.fetch(byte))
          cursor += 1
        end
      end

      def self.restore(labels, data)
        predicates = data.map { |definition| new(**definition) }
        labels.map do |row|
          row.map do |rule, pattern, bol, condition|
            condition = predicates.fetch(condition.first) if condition.is_a?(Array)
            [rule, pattern, bol, condition]
          end
        end
      end
    end

    module LookaheadAcceptance
      def valid_end?(byte)
        return end_anchor.eof.first if byte.nil? && end_anchor.is_a?(Lookahead)

        super
      end

      def valid_end_at?(input, cursor, lexer = nil, rule = nil, origin = cursor)
        return super unless end_anchor.is_a?(Lookahead)

        end_anchor.match?(input, cursor) do |probe|
          next unless lexer

          lexer.consume_step!
          lexer.ensure_lookahead_size!(probe - origin + 1, rule: rule)
        end
      end
    end
    Acceptance.prepend(LookaheadAcceptance)

    module LookaheadArtifact
      def load_dfa(data)
        return super unless data[:lookaheads]

        accepts = Lookahead.restore(data.fetch(:accepts), data.fetch(:lookaheads))
        super(data.merge(accepts: accepts))
      end
    end
    Generated.singleton_class.prepend(LookaheadArtifact)

    class DFA
      def lookahead?
        context_dependent_end? && accepts.any? { |labels| labels.any? { |label| label.end_anchor.is_a?(Lookahead) } }
      end

      def acceptance_data
        return { accepts: @accepts.map { |labels| labels.map(&:to_a) } } unless lookahead?

        predicates = {}
        rows = accepts.map do |labels|
          labels.map do |label|
            next label.to_a unless label.end_anchor.is_a?(Lookahead)

            index = predicates[label.end_anchor] ||= predicates.length
            [label.rule_index, label.pattern_index, label.bol_only, [index]]
          end
        end
        { accepts: rows, lookaheads: predicates.keys.map(&:to_h) }
      end
    end
  end
end
