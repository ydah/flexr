# frozen_string_literal: true

require_relative "data/grapheme_automaton"

module Flexr
  module Unicode
    module Grapheme
      BINARY_EDGES = [
        0, 0x00, 0x0c, 2,
        0, 0x0d, 0x0d, 1,
        0, 0x0e, 0xff, 2,
        1, 0x0a, 0x0a, 2
      ].freeze

      module_function

      def dfa(binary:)
        @dfa ||= {}
        @dfa[binary] ||= if binary
          build(BINARY_EDGES, 3)
        else
          data = Data::GraphemeAutomaton
          build(data::BYTE_EDGES.unpack("v*"), data::SCALAR_COUNT)
        end
      end

      def build(edges, scalar_count)
        classes = Automaton::ByteClassSet.new
        state_count = scalar_count
        edges.each_slice(4) do |from, lo, hi, to|
          classes.add_range(lo, hi)
          state_count = [state_count, from + 1, to + 1].max
        end
        ec, count = classes.build
        rows = Array.new(state_count) { Array.new(count) }
        edges.each_slice(4) do |from, lo, hi, to|
          rows.fetch(from).fill(to, ec.fetch(lo)..ec.fetch(hi))
        end
        accepts = Array.new(state_count) { [] }
        1.upto(scalar_count - 1) do |state|
          condition = rows.fetch(state).any? ? end_condition(state, rows, scalar_count, ec) : nil
          accepts[state] = [Automaton::Acceptance.new(rule_index: 0, pattern_index: 0, end_anchor: condition)]
        end

        Automaton::DFA.new(transitions: rows, accepts: accepts, ec: ec, class_count: count, start: 0, rule_ids: [0])
      end

      # Only completion of a joining scalar can rule out a boundary.
      def end_condition(start, rows, scalar_count, ec)
        states = [start]
        ids = { start => 0 }
        transitions = states.map do |state|
          next state unless state.is_a?(Integer)

          rows.fetch(state).map do |target|
            key = if target && target < scalar_count
              false
            else
              target || true
            end
            ids[key] ||= states.push(key).length - 1
          end
        end
        Automaton::Lookahead.new(transitions: transitions, eof: states.map { |state| state != false }, ec: ec)
      end
      private_class_method :build, :end_condition
    end
  end
end
