# frozen_string_literal: true

module Flexr
  module Automaton
    class DFA
      attr_reader :transitions, :accepts, :ec, :class_count, :start, :states, :rule_ids, :packed, :direct

      def initialize(transitions:, accepts:, ec:, class_count:, start:, rule_ids:, packed: nil, direct: nil)
        @transitions = transitions.map(&:freeze).freeze
        @accepts = accepts.map do |rules|
          rules.map do |acceptance|
            next acceptance if acceptance.is_a?(Acceptance)

            Acceptance.new(rule_index: acceptance[0], pattern_index: acceptance[1],
                           bol_only: acceptance[2], end_anchor: acceptance[3])
          end.freeze
        end.freeze
        @ec = ec.freeze
        @class_count = class_count
        @start = start
        @states = transitions.length
        @rule_ids = rule_ids.map { |id| id.respond_to?(:rule_index) ? id.rule_index : id }.uniq.sort.freeze
        @packed = freeze_representation(packed)
        @direct = freeze_representation(direct)
        freeze
      end

      def transition(state, byte)
        class_id = @ec[byte]
        return @transitions[state][class_id] unless @packed

        cursor = state
        loop do
          index = @packed.fetch(:base).fetch(cursor) + class_id
          return @packed.fetch(:next).fetch(index) if @packed.fetch(:check)[index] == cursor

          fallback = @packed[:fallback]&.fetch(cursor)
          return @packed.fetch(:default).fetch(cursor) unless fallback

          cursor = fallback
        end
      end

      # Generated direct lexers use a flattened dispatch representation. The
      # interpreter keeps this route separate from packed/table equivalence.
      def transition_direct(state, byte)
        if @direct
          class_id = @ec[byte]
          value = @direct.fetch(:nxt).fetch((state * @direct.fetch(:classes)) + class_id)
          return value >= 0 ? value : nil
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
