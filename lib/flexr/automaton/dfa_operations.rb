# frozen_string_literal: true

module Flexr
  module Automaton
    module DFAOperations
      module_function

      def difference(left, right, &)
        product(left, right, intersection: false, &).first
      end

      def product(left, right, intersection:)
        classes = {}
        ec = left.ec.zip(right.ec).map { |pair| classes[pair] ||= classes.length }
        left_classes, right_classes = classes.keys.transpose
        states = [[left.start, right.start]]
        ids = { states.first => 0 }
        transitions = []
        accepts = []
        overlap = false
        cursor = 0
        while cursor < states.length
          left_state, right_state = states.fetch(cursor)
          a = left.transitions.fetch(left_state)
          # A missing transition on the right enters a rejecting sink.
          b = right.transitions.fetch(right_state) if right_state
          transitions << left_classes.each_with_index.map do |class_id, index|
            next_left = a.fetch(class_id)
            next unless next_left

            next_right = right_state && b.fetch(right_classes.fetch(index))
            next if intersection && !next_right

            next_pair = [next_left, next_right]
            ids[next_pair] ||= begin
              id = states.length
              yield id
              states << next_pair
              id
            end
          end
          left_accept = left.accepts.fetch(left_state)
          right_accept = !right_state.nil? && !right.accepts.fetch(right_state).empty?
          overlap ||= right_accept && !left_accept.empty?
          accepts << (right_accept == intersection ? left_accept : [])
          cursor += 1
        end

        dfa = DFA.new(transitions: transitions, accepts: accepts, ec: ec, class_count: classes.length,
                      start: 0, rule_ids: left.rule_ids)
        [dfa, overlap]
      end

      def first_ending(dfa)
        transitions = dfa.transitions.each_with_index.map do |row, state|
          dfa.accepts.fetch(state).empty? ? row : Array.new(dfa.class_count)
        end
        DFA.new(transitions: transitions, accepts: dfa.accepts, ec: dfa.ec, class_count: dfa.class_count,
                start: dfa.start, rule_ids: dfa.rule_ids)
      end
    end
  end
end
