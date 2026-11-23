# frozen_string_literal: true

module Flexr
  module Automaton
    class BackupAnalysis
      Result = Data.define(:maximum_bytes, :example, :cycle) do
        def unbounded?
          maximum_bytes.nil?
        end
      end

      def initialize(dfa)
        @dfa = dfa
        @accepting = dfa.accepts.map { |acceptances| !acceptances.empty? }
        @edges = dfa.transitions.map { |row| row.compact.uniq }
        @extensions = @edges.map { |destinations| destinations.reject { |state| @accepting[state] } }
      end

      def analyze
        roots = backup_roots
        return Result.new(0, nil, nil) if roots.empty?

        order = finishing_order(roots)
        cycles = cycle_states(order)
        return Result.new(maximum_length(order, roots), nil, nil) unless cycles.any?

        prefix, state = shortest_prefix(cycles)
        Result.new(nil, prefix.freeze, shortest_cycle(state).freeze)
      end

      def memo_states
        roots = backup_roots
        body = cyclic_states_from(roots)
        recovery = cyclic_states_from(roots + [@dfa.start]) unless @accepting[@dfa.start]
        [body, recovery == body ? nil : recovery]
      end

      private

      def backup_roots
        reachable_states.select { |state| @accepting[state] }.flat_map { |state| @extensions[state] }.uniq
      end

      def cyclic_states_from(roots)
        return if roots.empty?

        cycles = cycle_states(finishing_order(roots))
        cycles.freeze if cycles.any?
      end

      def reachable_states
        seen = Array.new(@dfa.states)
        seen[@dfa.start] = true
        states = [@dfa.start]
        states.each do |state|
          @edges[state].each do |target|
            next if seen[target]

            seen[target] = true
            states << target
          end
        end
        states
      end

      def finishing_order(roots)
        order = []
        seen = Array.new(@dfa.states)
        stack = roots.dup
        until stack.empty?
          state = stack.pop
          if state.negative?
            order << ~state
          elsif !seen[state]
            seen[state] = true
            # Use a return marker so deep DFAs never consume the Ruby call stack.
            stack << ~state
            stack.concat(@extensions[state])
          end
        end
        order
      end

      def cycle_states(order)
        predecessors = Array.new(@dfa.states) { [] }
        order.each { |state| @extensions[state].each { |target| predecessors[target] << state } }
        cycles = Array.new(@dfa.states)
        assigned = Array.new(@dfa.states)
        order.reverse_each do |state|
          next if assigned[state]

          component = [state]
          assigned[state] = true
          component.each do |member|
            predecessors[member].each do |source|
              next if assigned[source]

              assigned[source] = true
              component << source
            end
          end
          component.each { |member| cycles[member] = true } if component.length > 1 || @extensions[state].include?(state)
        end
        cycles
      end

      def maximum_length(order, roots)
        lengths = Array.new(@dfa.states, 0)
        order.each do |state|
          lengths[state] = 1 + (@extensions[state].map { |target| lengths[target] }.max || 0)
        end
        roots.map { |state| lengths[state] }.max
      end

      def shortest_prefix(cycles)
        start = (@dfa.start * 2) + (@accepting[@dfa.start] ? 1 : 0)
        paths = [[start, nil, nil]]
        seen = { start => true }
        paths.each_with_index do |(key, _, _), index|
          state, accepted = key.divmod(2)
          return [Analysis.example_input(paths, index), state] if accepted == 1 && cycles[state]

          each_transition(state) do |target, byte|
            next_key = (target * 2) + (@accepting[target] ? 1 : accepted)
            next if seen[next_key]

            seen[next_key] = true
            paths << [next_key, index, byte]
          end
        end
      end

      def shortest_cycle(start)
        paths = [[start, nil, nil]]
        seen = { start => true }
        paths.each_with_index do |(state, _, _), index|
          each_transition(state) do |target, byte|
            next if @accepting[target]
            return Analysis.example_input(paths, index) << byte if target == start
            next if seen[target]

            seen[target] = true
            paths << [target, index, byte]
          end
        end
      end

      def each_transition(state)
        @bytes ||= Analysis.joint_byte_representatives(@dfa, @dfa)
        @bytes.each do |byte|
          target = @dfa.transition(state, byte)
          yield target, byte if target
        end
      end
    end
  end
end
