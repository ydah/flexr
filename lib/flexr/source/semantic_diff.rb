# frozen_string_literal: true

require_relative "../automaton/token_diff"
require_relative "action_effects"

module Flexr
  module Source
    class SemanticDiff
      Input = Data.define(:compiled, :backend, :rules, :encoding, :options, :inclusive_states, :effects, :keyword_effects) do
        def self.from_source(parsed:, compiled:, backend:)
          config = parsed.config
          inclusive_states = parsed.states.filter_map { |name, state| name if state.fetch(:inclusive) }
          effects = parsed.rules.to_h { |rule| [rule.index, ActionEffects.for_rule(rule)] }
          new(compiled: compiled, backend: backend, encoding: config.fetch(:encoding), options: config.fetch(:options, {}),
              inclusive_states: inclusive_states, effects: effects)
        end

        def self.from_lexer(lexer, ordered: true)
          raise ArgumentError, "expected a Flexr::Lexer class" unless lexer.is_a?(Class) && lexer <= Lexer

          compiled = lexer.compile!
          spec = lexer.__flexr_spec
          if ordered && spec.backend == :firstmatch
            spec.rules = spec.rules.map do |rule|
              rule.dup.tap do |copy|
                copy.contextual_patterns = nil
                copy.capture_patterns = nil
              end
            end
            compiled = Automaton::Compiler.new(spec, retain_firstmatch_order: true).compile
          end
          effects = compiled.rules.to_h do |rule|
            effect = if rule.skip?
              ActionEffects.effect([:skip], nil, [])
            elsif rule.emit?
              ActionEffects.effect(rule.action, rule.channel, [])
            end
            [rule.index, effect]
          end
          inclusive_states = spec.states.values.filter_map { |state| state.name if state.inclusive }
          new(compiled: compiled, backend: spec.backend, encoding: spec.encoding, options: spec.options,
              inclusive_states: inclusive_states, effects: effects)
        end

        def initialize(compiled:, backend:, encoding:, options:, inclusive_states:, effects:)
          rules = prepare_trailing(compiled.rules, encoding, options[:unicode] == true)
          super(compiled: compiled, backend: backend, rules: rules, encoding: encoding, options: options,
                inclusive_states: inclusive_states, effects: effects, keyword_effects: remaps(rules, options, effects))
        end

        def side(name, ordered: true)
          if ordered && backend == :firstmatch
            inclusive = inclusive_states.include?(name)
            active = rules.select { |rule| rule.states.include?(name) || (inclusive && rule.states.include?(:initial)) }
            Automaton::TokenDiff::FirstmatchSide.new(rules: active.sort_by(&:index), effects: effects, keyword_effects: keyword_effects)
          else
            dfa = compiled.machines.fetch(name).dfa
            Automaton::TokenDiff::Side.new(dfa: dfa, rules: rules, effects: effects, keyword_effects: keyword_effects,
                                          allow_empty_match: options[:allow_empty_match] == true,
                                          shortest: options[:shortest_states]&.include?(name) == true)
          end
        end

        private

        def prepare_trailing(rules, encoding, unicode)
          trailing = {}
          rules.map do |rule|
            next rule unless rule.trailing && !rule.trailing_dfa

            dfa = trailing[rule.trailing] ||= Flexr.compile_pattern(rule.trailing, encoding: encoding, options: { unicode: unicode })
            rule.dup.tap { |copy| copy.trailing_dfa = dfa }
          rescue CompileError => e
            e.diagnostic.location ||= rule.location if e.diagnostic
            raise
          end
        end

        def remaps(rules, options, effects)
          tables = options.fetch(:keyword_tables, {})
          rules.each_with_object({}) do |rule, result|
            next unless rule.emit? && !rule.channel

            effect = effects.fetch(rule.index)
            table = tables[effect&.token]
            next unless table

            result[rule.index] = table.transform_values { |(type, _)| effect.with(token: type) }
          end
        end
      end

      StateResult = Data.define(:state, :result)

      def initialize(left, right, limit:)
        @left = left
        @right = right
        @limit = limit
      end

      def states(names = @left.compiled.states | @right.compiled.states)
        reason = incomparable_reason
        names.map do |name|
          result = if !@left.compiled.machines.key?(name)
            different_state("state is absent on the left")
          elsif !@right.compiled.machines.key?(name)
            different_state("state is absent on the right")
          elsif reason
            Automaton::TokenDiff::Result.new(status: :inconclusive, input: nil, offset: nil, left: nil, right: nil, reason: reason)
          else
            Automaton::TokenDiff.compare(@left.side(name), @right.side(name), encoding: @left.encoding, limit: @limit)
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
        nil
      end
    end
  end
end
