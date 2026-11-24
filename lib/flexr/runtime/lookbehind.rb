# frozen_string_literal: true

module Flexr
  module Runtime
    module Lookbehind
      def self.graphs(compiled)
        machines = compiled.machines.values.map { |machine| machine.dfa.left_context }
        trailing = compiled.rules.map { |rule| rule.trailing_dfa&.left_context }
        predicates = contextual_patterns(compiled).flat_map do |pattern|
          pattern.instructions.filter_map do |kind, first, _, graph|
            next graph if kind == :context_predicate

            first.left_context if kind == :span
          end
        end
        (machines + trailing + predicates).compact.uniq(&:object_id)
      end

      def self.contextual_patterns(compiled)
        compiled.rules.flat_map do |rule|
          (Array(rule.contextual_patterns) + Array(rule.capture_patterns)).select { |pattern| pattern.respond_to?(:instructions) }
        end.uniq(&:object_id)
      end

      def self.install(klass, compiled)
        klass.include(self) unless graphs(compiled).empty?
      end

      private

      def reset_input_cursor(input, encoding)
        super
        @buffer.extend(History)
        compiled = self.class.__flexr_compiled
        bytes = Lookbehind.contextual_patterns(compiled).filter_map(&:history_bytes).max
        live = input.is_a?(String) && !@buffer.source.frozen?
        @buffer.initialize_left_context(Lookbehind.graphs(compiled), bytes, live: live)
      end

      def update_position
        super
        @buffer.commit_left_context(@position)
      end

      module History
        Prefix = Struct.new(:base_state, :committed, :committed_state, :cursor, :state)

        def initialize_left_context(graphs, replay_bytes, live:)
          @live_left_input = live
          @replay_bytes = replay_bytes
          @replay_prefix = "".b if replay_bytes
          @left_prefixes = {}.compare_by_identity
          graphs.each { |graph| @left_prefixes[graph] = Prefix.new(0, 0, 0, 0, 0) }
        end

        def left_state_at(graph, ending)
          prefix = @left_prefixes.fetch(graph)
          return graph.advance(self, prefix.base_state, base_offset, ending) if @live_left_input
          if ending < prefix.cursor
            return graph.advance(self, prefix.committed_state, prefix.committed, ending) if
              prefix.committed.between?(base_offset, ending)

            return graph.advance(self, prefix.base_state, base_offset, ending)
          end

          prefix.state = graph.advance(self, prefix.state, prefix.cursor, ending)
          prefix.cursor = ending
          prefix.state
        end

        def commit_left_context(ending)
          return if @live_left_input

          @left_prefixes.each do |graph, prefix|
            prefix.committed_state = left_state_at(graph, ending)
            prefix.committed = ending
          end
        end

        def left_bytes_at(ending, count)
          starting = [ending - count, 0].max
          retained = [starting, base_offset].max
          bytes = byteslice(retained, ending - retained).b
          return bytes if starting >= base_offset

          @replay_prefix.byteslice(-(base_offset - starting)..) + bytes
        end

        def discard_before(position)
          ending = [position, bytesize].min
          if ending > base_offset
            @replay_prefix = left_bytes_at(ending, @replay_bytes) if @replay_bytes
            @left_prefixes.each do |graph, prefix|
              prefix.base_state = left_state_at(graph, ending)
            end
          end
          super
        end
      end
    end

    module LookbehindClass
      private

      def freeze_compiled!(compiled)
        super.tap { Lookbehind.install(self, compiled) }
      end
    end
  end
  DSL.prepend(Runtime::LookbehindClass)

  module Automaton
    module LookbehindArtifact
      def load_dfa(data)
        return super unless (graph = data[:left_context])

        super(data.merge(left_context: LeftContext::Graph.new(**graph)))
      end
    end
    Generated.singleton_class.prepend(LookbehindArtifact)
  end
end
