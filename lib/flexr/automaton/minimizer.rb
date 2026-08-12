# frozen_string_literal: true

module Flexr
  module Automaton
    module Minimizer
      module_function

      def minimize(dfa)
        dead = dfa.states
        rows = dfa.transitions.map { |row| row.map { |destination| destination.nil? ? dead : destination } }
        rows << Array.new(dfa.class_count, dead)
        partitions = initial_partitions(dfa, dead)
        predecessors = predecessor_index(rows, dfa.class_count)
        partitions = refine(partitions, predecessors, dfa.class_count)
        rebuild(dfa, partitions, dead)
      end

      def initial_partitions(dfa, dead)
        (0..dead).group_by { |state| state == dead ? [] : dfa.accepts[state] }.values
      end

      def predecessor_index(rows, class_count)
        Array.new(class_count) { Array.new(rows.length) { [] } }.tap do |index|
          rows.each_with_index do |row, state|
            row.each_with_index { |destination, class_id| index[class_id][destination] << state }
          end
        end
      end

      def refine(partitions, predecessors, class_count)
        worklist = partitions.dup
        pending = {}.compare_by_identity
        partitions.each { |partition| pending[partition] = true }
        cursor = 0
        while cursor < worklist.length
          splitter = worklist.fetch(cursor)
          cursor += 1
          next unless pending.delete(splitter)

          class_count.times do |class_id|
            marked = splitter.each_with_object({}) do |state, result|
              predecessors[class_id][state].each { |predecessor| result[predecessor] = true }
            end
            next if marked.empty?

            partitions = split_partitions(partitions, marked, worklist, pending)
          end
        end
        partitions
      end

      def split_partitions(partitions, marked, worklist, pending)
        partitions.flat_map do |partition|
          inside, outside = partition.partition { |state| marked[state] }
          next [partition] if inside.empty? || outside.empty?

          if pending.delete(partition)
            enqueue(inside, worklist, pending)
            enqueue(outside, worklist, pending)
          else
            enqueue(inside.length <= outside.length ? inside : outside, worklist, pending)
          end
          [inside, outside]
        end
      end

      def enqueue(partition, worklist, pending)
        worklist << partition
        pending[partition] = true
      end

      def rebuild(dfa, partitions, dead)
        groups = group_ids(partitions)
        dead_group = groups.fetch(dead)
        start_group = groups.fetch(dfa.start)
        representatives = partitions.map { |partition| partition.find { |state| state != dead } }
        order = reachable_groups(dfa, groups, representatives, start_group, dead_group)
        index = order.each_with_index.to_h
        transitions = order.map do |group|
          representative = representatives.fetch(group)
          dfa.transitions.fetch(representative).map do |destination|
            next nil if destination.nil? || groups.fetch(destination) == dead_group

            index.fetch(groups.fetch(destination))
          end
        end
        accepts = order.map { |group| dfa.accepts.fetch(representatives.fetch(group)) }
        rule_ids = accepts.flatten.map(&:rule_index).uniq.sort
        DFA.new(transitions: transitions, accepts: accepts, ec: dfa.ec, class_count: dfa.class_count,
                start: 0, rule_ids: rule_ids)
      end

      def group_ids(partitions)
        partitions.each_with_index.with_object({}) do |(partition, group), result|
          partition.each { |state| result[state] = group }
        end
      end

      def reachable_groups(dfa, groups, representatives, start_group, dead_group)
        result = []
        queue = [start_group]
        seen = {}
        cursor = 0
        while cursor < queue.length
          group = queue.fetch(cursor)
          cursor += 1
          next if seen[group] || (group == dead_group && group != start_group)

          seen[group] = true
          result << group
          representative = representatives.fetch(group)
          dfa.transitions.fetch(representative).compact.each { |destination| queue << groups.fetch(destination) }
        end
        result
      end
    end
  end
end
