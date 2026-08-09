# frozen_string_literal: true

module Flexr
  module Automaton
    module Minimizer
      module_function

      def minimize(dfa)
        partitions = initial_partitions(dfa)
        loop do
          groups = group_ids(partitions)
          refined = partitions.flat_map do |partition|
            partition.group_by do |state|
              [dfa.accepts[state], dfa.transitions[state].map { |destination| destination.nil? ? -1 : groups[destination] }]
            end.values
          end
          break if refined == partitions

          partitions = refined
        end
        rebuild(dfa, partitions)
      end

      def initial_partitions(dfa)
        (0...dfa.states).group_by { |state| dfa.accepts[state] }.values
      end

      def group_ids(partitions)
        ids = {}
        partitions.each_with_index { |partition, id| partition.each { |state| ids[state] = id } }
        ids
      end

      def rebuild(dfa, partitions)
        groups = group_ids(partitions)
        start_group = groups.fetch(dfa.start)
        order = bfs_groups(dfa, groups, start_group)
        index = order.each_with_index.to_h
        transitions = order.map do |group|
          representative = partitions[group].first
          dfa.transitions[representative].map { |destination| destination.nil? ? nil : index[groups[destination]] }
        end
        accepts = order.map { |group| dfa.accepts[partitions[group].first] }
        rule_ids = accepts.flatten.map(&:rule_index).uniq.sort
        DFA.new(transitions: transitions, accepts: accepts, ec: dfa.ec, class_count: dfa.class_count,
                start: 0, rule_ids: rule_ids)
      end

      def bfs_groups(dfa, groups, start_group)
        result = []
        queue = [start_group]
        seen = {}
        until queue.empty?
          group = queue.shift
          next if seen[group]

          seen[group] = true
          result << group
          representative = dfa.transitions[group_members(dfa, groups, group).first]
          representative.compact.each { |destination| queue << groups[destination] }
        end
        result
      end

      def group_members(dfa, groups, group)
        (0...dfa.states).select { |state| groups[state] == group }
      end
    end
  end
end
