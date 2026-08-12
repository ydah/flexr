# frozen_string_literal: true

module Flexr
  module Automaton
    class TransitionRows
      include Enumerable

      attr_reader :length

      def initialize(length, &loader)
        @length = length
        @loader = loader
        @rows = Array.new(length)
        freeze
      end

      alias size length

      def [](state)
        return unless state&.between?(0, length - 1)

        @rows[state] ||= @loader.call(state).freeze
      end

      def fetch(state)
        return self[state] if state.between?(0, length - 1)

        raise IndexError, "transition row #{state} is out of bounds"
      end

      def each
        return enum_for(__method__) unless block_given?

        length.times { |state| yield self[state] }
      end

      def each_index(&)
        return enum_for(__method__) unless block_given?

        length.times(&)
      end

      def materialized_count
        @rows.count { |row| !row.nil? }
      end
    end

    class DFA
      attr_reader :transitions, :accepts, :ec, :class_count, :start, :states, :rule_ids, :packed, :direct

      def initialize(accepts:, ec:, class_count:, start:, rule_ids:, transitions: nil, packed: nil, direct: nil,
                     state_count: nil)
        @packed = freeze_representation(packed)
        @direct = freeze_representation(direct)
        @states = state_count || transitions&.length || direct_state_count
        raise ArgumentError, "state_count is required without dense transitions" unless @states

        @transitions = transition_rows(transitions)
        @accepts = accepts.map do |rules|
          rules.map do |acceptance|
            next acceptance.freeze if acceptance.is_a?(Acceptance)

            Acceptance.new(rule_index: acceptance[0], pattern_index: acceptance[1],
                           bol_only: acceptance[2], end_anchor: acceptance[3]).freeze
          end.freeze
        end.freeze
        @ec = ec.freeze
        @class_count = class_count
        @start = start
        @rule_ids = rule_ids.map { |id| id.respond_to?(:rule_index) ? id.rule_index : id }.uniq.sort.freeze
        freeze
      end

      def transition(state, byte)
        class_id = @ec[byte]
        return direct_transition(state, class_id) if @direct
        return @transitions[state][class_id] unless @packed

        packed_transition(state, class_id)
      end

      # Generated direct lexers use a flattened dispatch representation. The
      # interpreter keeps this route separate from packed/table equivalence.
      def transition_direct(state, byte)
        if @direct
          class_id = @ec[byte]
          return direct_transition(state, class_id)
        end

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

      private

      def transition_rows(transitions)
        return transitions.map(&:freeze).freeze if transitions
        if @packed
          return TransitionRows.new(states) do |state|
            Array.new(class_count) { |class_id| packed_transition(state, class_id) }
          end
        end
        if @direct
          return TransitionRows.new(states) do |state|
            Array.new(class_count) { |class_id| direct_transition(state, class_id) }
          end
        end

        raise ArgumentError, "a transition representation is required"
      end

      def packed_transition(state, class_id)
        cursor = state
        loop do
          index = @packed.fetch(:base).fetch(cursor) + class_id
          return @packed.fetch(:next).fetch(index) if @packed.fetch(:check)[index] == cursor

          fallback = @packed[:fallback]&.fetch(cursor)
          return @packed.fetch(:default).fetch(cursor) unless fallback

          cursor = fallback
        end
      end

      def direct_transition(state, class_id)
        value = @direct.fetch(:nxt).fetch((state * @direct.fetch(:classes)) + class_id)
        value >= 0 ? value : nil
      end

      def direct_state_count
        return unless @direct

        @direct.fetch(:nxt).length / @direct.fetch(:classes)
      end

      def freeze_representation(representation)
        return unless representation

        representation.each_value { |value| value.freeze if value.respond_to?(:freeze) }
        representation.freeze
      end
    end

    class ReferenceDFA
      def initialize(regexp, unicode: false)
        source, options = if reference_pattern?(regexp, unicode: unicode)
          converted = Unicode::ReferenceRegexp.compiled(
            regexp, encoding: regexp.encoding, options: regexp.options, unicode: unicode
          )
          [converted.source, converted.options]
        else
          [regexp.source, regexp.options]
        end
        @regexp = ::Regexp.new("\\A(?:#{source})\\z", options)
      end

      def accept?(bytes)
        data = bytes.dup.force_encoding(@regexp.encoding)
        @regexp.match?(data)
      rescue ArgumentError, EncodingError
        false
      end

      def stats
        { states: 0, classes: 0, accepting_states: 0, reference: true }
      end

      private

      def reference_pattern?(regexp, unicode: false)
        return true if regexp.source.match?(/\\[pP]\{/) || regexp.source.match?(/\[:(?:\^)?[a-z]+:\]/)

        unicode && regexp.encoding != Encoding::BINARY && regexp.source.match?(/\\[dDwWsS]/)
      end
    end
  end
end
