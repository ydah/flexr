# frozen_string_literal: true

module Flexr
  module Automaton
    class LazyDerivativeDFA
      attr_reader :start, :accepts, :ec, :class_count, :rule_ids, :transitions

      def initialize(vector, conditions, terms, ec, class_count, &state_limit)
        @start = 0
        @ec = ec
        @class_count = class_count
        @representatives = ec.each_index.uniq { |byte| ec.fetch(byte) }
        @conditions = conditions.map(&:freeze).freeze
        @rule_ids = conditions.map(&:rule_index).uniq.sort.freeze
        @terms = terms
        @state_limit = state_limit
        @mutex = Mutex.new
        @ids = {}
        @vectors = []
        @accepts = []
        @transitions = []
        add_state(vector)
      end

      def states
        @transitions.length
      end

      def direct = nil

      def transition(state, byte)
        class_id = @ec.fetch(byte)
        targets = @transitions.fetch(state)
        target = targets[class_id]
        if target.nil?
          target = @mutex.synchronize do
            targets[class_id] = successor(state, class_id) if targets[class_id].nil?
            targets[class_id]
          end
        end
        target || nil
      end
      alias transition_direct transition

      private

      def successor(state, class_id)
        byte = @representatives.fetch(class_id)
        vector = @terms.advance(@vectors.fetch(state), byte, class_id)
        return false if vector.empty?

        @ids.fetch(vector) do
          @state_limit.call(states)
          add_state(vector)
        end
      end

      def add_state(vector)
        state = @transitions.length
        accepts = vector.filter_map { |pattern, term| @conditions.fetch(pattern) if @terms.nullable?(term) }
        @vectors << vector
        @accepts << accepts.uniq.freeze
        @transitions << []
        @ids[vector] = state
      end
    end
  end
end
