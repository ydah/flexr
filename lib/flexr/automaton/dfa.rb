# frozen_string_literal: true

module Flexr
  module Automaton
    class DFA
      attr_reader :transitions, :accepts, :ec, :class_count, :start, :states, :rule_ids, :packed

      def initialize(transitions:, accepts:, ec:, class_count:, start:, rule_ids:, packed: nil)
        @transitions = transitions.freeze
        @accepts = accepts.freeze
        @ec = ec.freeze
        @class_count = class_count
        @start = start
        @states = transitions.length
        @rule_ids = rule_ids.freeze
        @packed = packed
      end

      def transition(state, byte)
        class_id = @ec[byte]
        return @transitions[state][class_id] unless @packed

        index = @packed.fetch(:base).fetch(state) + class_id
        return @packed.fetch(:default).fetch(state) unless @packed.fetch(:check)[index] == class_id

        @packed.fetch(:next).fetch(index)
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

    class ReferenceDFA
      def initialize(regexp)
        @regexp = ::Regexp.new("\\A(?:#{regexp.source})\\z", regexp.options)
      end

      def accept?(bytes)
        @regexp.match?(bytes)
      rescue ArgumentError
        false
      end

      def stats
        { states: 0, classes: 0, accepting_states: 0, reference: true }
      end
    end
  end
end
