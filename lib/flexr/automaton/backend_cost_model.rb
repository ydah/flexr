# frozen_string_literal: true

module Flexr
  module Automaton
    module BackendCostModel
      Metrics = Struct.new(:dense_bytes, :packed_bytes, :lookup_samples, keyword_init: true) do
        def direct_score
          dense_bytes + lookup_samples
        end

        def table_score
          packed_bytes + (lookup_samples * 3)
        end
      end

      module_function

      def choose(compiled)
        metrics = compiled.machines.values.map { |machine| metrics_for(machine.dfa) }
        direct_score = metrics.sum(&:direct_score)
        table_score = metrics.sum(&:table_score)
        direct_score < table_score ? :direct : :table
      end

      def metrics_for(dfa)
        cells = dfa.states * dfa.class_count
        overrides = dfa.transitions.sum do |row|
          default = row.tally.max_by { |_value, count| count }&.first
          row.count { |value| value != default }
        end
        packed_integers = (overrides * 2) + (dfa.states * 2)
        Metrics.new(
          dense_bytes: cells * 4,
          packed_bytes: packed_integers * 4,
          lookup_samples: dfa.states * [dfa.class_count, 16].min
        ).freeze
      end
    end
  end
end
