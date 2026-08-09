# frozen_string_literal: true

module Flexr
  module Automaton
    class DFA
      attr_reader :transitions, :accepts, :ec, :class_count, :start, :states, :rule_ids

      def initialize(transitions:, accepts:, ec:, class_count:, start:, rule_ids:)
        @transitions = transitions.freeze
        @accepts = accepts.freeze
        @ec = ec.freeze
        @class_count = class_count
        @start = start
        @states = transitions.length
        @rule_ids = rule_ids.freeze
      end

      def transition(state, byte)
        @transitions[state][@ec[byte]]
      end

      def accept?(bytes)
        data = bytes.dup.force_encoding(Encoding::BINARY)
        state = @start
        data.each_byte do |byte|
          state = transition(state, byte)
          return false unless state
        end
        !@accepts[state].empty?
      end

      def stats
        { states: states, classes: class_count, accepting_states: accepts.count { |rules| !rules.empty? } }
      end
    end
  end
end
