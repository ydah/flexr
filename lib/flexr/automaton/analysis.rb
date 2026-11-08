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
        representatives = Array.new(dfa.class_count)
        dfa.ec.each_with_index { |class_id, byte| representatives[class_id] ||= byte }
        self_loops = representatives.each_index.map do |class_id|
          byte = representatives.fetch(class_id)
          byte && dfa.transition(state, byte) == state
        end
        dfa.ec.each_index.select { |byte| self_loops.fetch(dfa.ec.fetch(byte)) }
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

      def shadowing_examples(dfa, rule_indices)
        remaining = (rule_indices & dfa.rule_ids).to_h { |index| [index, true] }
        return {} if remaining.empty?

        examples = {}
        queue = [[dfa.start, nil, nil]]
        # Visiting the start again permits a nonempty example when it accepts and loops.
        visited = {}
        bytes = joint_byte_representatives(dfa, dfa)
        cursor = 0
        while cursor < queue.length
          state = queue.fetch(cursor).first
          accepts = dfa.accepts.fetch(state)
          winner = accepts.min_by(&:rule_index)&.rule_index
          if cursor.positive? && winner
            shadowed = accepts.map(&:rule_index).uniq.select { |index| index > winner && remaining.key?(index) }
            unless shadowed.empty?
              input = example_input(queue, cursor)
              shadowed.each do |index|
                examples[index] = [input, winner]
                remaining.delete(index)
              end
              return examples if remaining.empty?
            end
          end

          bytes.each do |byte|
            target = dfa.transition(state, byte)
            next if target.nil? || visited[target]

            visited[target] = true
            queue << [target, cursor, byte]
          end
          cursor += 1
        end
        examples
      end

      def example_input(paths, cursor)
        bytes = []
        while (parent = paths.fetch(cursor)[1])
          bytes << paths.fetch(cursor)[2]
          cursor = parent
        end
        bytes.reverse.pack("C*")
      end

      def accepting?(dfa, state)
        state && !dfa.accepts.fetch(state).empty?
      end
    end
  end
end
