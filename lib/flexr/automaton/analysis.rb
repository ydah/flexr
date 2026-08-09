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
        dfa.transitions[state].each_with_index.each_with_object([]) do |(destination, class_id), result|
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
    end
  end
end
