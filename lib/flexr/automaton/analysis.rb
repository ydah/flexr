# frozen_string_literal: true

module Flexr
  module Automaton
    module Analysis
      module_function

      def unreachable_rules(compiled)
        present = compiled.machines.values.flat_map { |machine| machine.dfa.rule_ids }.uniq
        compiled.rules.reject { |rule| present.include?(rule.index) }
      end

      def needs_backup?(dfa)
        dfa.transitions.each_index.any? do |state|
          next false if dfa.accepts[state].empty?

          dfa.transitions[state].compact.any? { |destination| dfa.accepts[destination].empty? }
        end
      end

      def self_loop_set(dfa, state)
        dfa.transitions[state].each_with_index.with_object([]) do |(destination, class_id), result|
          next unless destination == state

          dfa.ec.each_with_index do |value, byte|
            result << byte if value == class_id
          end
        end
      end

      def dead_states(dfa)
        dfa.transitions.each_index.select do |state|
          dfa.accepts[state].empty? && dfa.transitions[state].compact.all? { |destination| destination == state }
        end
      end

      def firstmatch_counterexample(first, second)
        queue = [[first.start, second.start, false, +"".b]]
        visited = { [first.start, second.start, false] => true }
        bytes = joint_byte_representatives(first, second)
        cursor = 0

        while cursor < queue.length
          first_state, second_state, first_seen, input = queue.fetch(cursor)
          cursor += 1
          bytes.each do |byte|
            next_first = first_state && first.transition(first_state, byte)
            next_second = second_state && second.transition(second_state, byte)
            next unless next_second

            next_input = input + byte.chr(Encoding::BINARY)
            next_first_seen = first_seen || accepting?(first, next_first)
            return next_input if next_first_seen && accepting?(second, next_second) && !accepting?(first, next_first)

            key = [next_first, next_second, next_first_seen]
            next if visited[key]

            visited[key] = true
            queue << [next_first, next_second, next_first_seen, next_input]
          end
        end
        nil
      end

      def joint_byte_representatives(first, second)
        representatives = {}
        256.times do |byte|
          key = [first.ec[byte], second.ec[byte]]
          representatives[key] ||= byte
        end
        representatives.values.sort_by { |byte| [byte.between?(32, 126) ? 0 : 1, byte] }
      end

      def accepting?(dfa, state)
        state && !dfa.accepts.fetch(state).empty?
      end
    end
  end
end
