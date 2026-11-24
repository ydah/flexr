# frozen_string_literal: true

require_relative "../automaton/token_diff"
require_relative "action_effects"

module Flexr
  module Source
    class SemanticDiff
      Input = Data.define(:parsed, :compiled, :backend, :rules) do
        def initialize(parsed:, compiled:, backend:)
          rules = compiled.rules
          rules = prepare_trailing(rules, parsed.config) unless backend == :firstmatch
          super(parsed: parsed, compiled: compiled, backend: backend, rules: rules)
        end

        def encoding = parsed.config.fetch(:encoding)

        def options = parsed.config.fetch(:options, {})

        private

        def prepare_trailing(rules, config)
          trailing = {}
          rules.map do |rule|
            next rule unless rule.trailing && !rule.trailing_dfa

            dfa = trailing[rule.trailing] ||= Flexr.compile_pattern(
              rule.trailing, encoding: config.fetch(:encoding),
              options: { unicode: config.dig(:options, :unicode) == true }
            )
            rule.dup.tap { |copy| copy.trailing_dfa = dfa }
          rescue CompileError => e
            e.diagnostic.location ||= rule.location if e.diagnostic
            raise
          end
        end
      end

      StateResult = Data.define(:state, :result)

      def initialize(left, right, limit:)
        @left = left
        @right = right
        @limit = limit
      end

      def states
        reason = incomparable_reason
        left_inputs, right_inputs = [@left, @right].map { |input| machine_inputs(input) } unless reason
        (@left.compiled.states | @right.compiled.states).map do |name|
          result = if !@left.compiled.machines.key?(name)
            different_state("state is absent on the left")
          elsif !@right.compiled.machines.key?(name)
            different_state("state is absent on the right")
          elsif reason
            Automaton::TokenDiff::Result.new(status: :inconclusive, input: nil, offset: nil, left: nil, right: nil, reason: reason)
          else
            Automaton::TokenDiff.compare(left_inputs.fetch(name), right_inputs.fetch(name), encoding: @left.encoding, limit: @limit)
          end
          StateResult.new(state: name, result: result)
        end
      end

      private

      def different_state(reason)
        Automaton::TokenDiff::Result.new(status: :different, input: nil, offset: nil, left: nil, right: nil, reason: reason)
      end

      def incomparable_reason
        return "input encodings differ" unless @left.encoding == @right.encoding
        return "firstmatch requires ordered regexp comparison" if [@left.backend, @right.backend].include?(:firstmatch)

        nil
      end

      def machine_inputs(input)
        effects = input.parsed.rules.to_h { |rule| [rule.index, ActionEffects.for_rule(rule)] }
        keyword_effects = keyword_effects(input, effects)
        input.compiled.machines.transform_values do |machine|
          Automaton::TokenDiff::Side.new(dfa: machine.dfa, rules: input.rules, effects: effects, keyword_effects: keyword_effects,
                                         allow_empty_match: input.options[:allow_empty_match] == true)
        end
      end

      def keyword_effects(input, effects)
        tables = input.options.fetch(:keyword_tables, {})
        input.compiled.rules.each_with_object({}) do |rule, remaps|
          next unless rule.emit? && !rule.channel

          effect = effects.fetch(rule.index)
          table = tables[effect&.token]
          next unless table

          remaps[rule.index] = table.transform_values { |(type, _)| effect.with(token: type) }
        end
      end
    end
  end
end
