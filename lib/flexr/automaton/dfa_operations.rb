# frozen_string_literal: true

module Flexr
  module Automaton
    module DFAOperations
      module_function

      def difference(left, right)
        classes = {}
        ec = left.ec.zip(right.ec).map { |pair| classes[pair] ||= classes.length }
        left_classes, right_classes = classes.keys.transpose
        states = [[left.start, right.start]]
        ids = { states.first => 0 }
        transitions = []
        accepts = []
        cursor = 0
        while cursor < states.length
          left_state, right_state = states.fetch(cursor)
          a = left.transitions.fetch(left_state)
          # A missing transition on the right enters a rejecting sink.
          b = right.transitions.fetch(right_state) if right_state
          transitions << left_classes.each_with_index.map do |class_id, index|
            next_left = a.fetch(class_id)
            next unless next_left

            next_pair = [next_left, right_state && b.fetch(right_classes.fetch(index))]
            ids[next_pair] ||= begin
              id = states.length
              yield id
              states << next_pair
              id
            end
          end
          accepts << (right_state && !right.accepts.fetch(right_state).empty? ? [] : left.accepts.fetch(left_state))
          cursor += 1
        end

        DFA.new(transitions: transitions, accepts: accepts, ec: ec, class_count: classes.length,
                start: 0, rule_ids: left.rule_ids)
      end
    end
  end
end
