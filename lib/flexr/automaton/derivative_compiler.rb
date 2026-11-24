# frozen_string_literal: true

require_relative "derivative_terms"
require_relative "derivative_residuals"

module Flexr
  module Automaton
    class DerivativeCompiler
      attr_reader :residuals

      def compile(patterns, retain_residuals: false, minimize: true, &state_limit)
        @residuals = nil
        terms = DerivativeTerms.new
        start = patterns.each_with_index.to_h { |(body, _), index| [index, terms.from_ast(body)] }.freeze
        conditions = patterns.map(&:last)
        operation = terms.operations.join(" and ") unless terms.operations.empty?
        ec, count = terms.byte_classes.build
        representatives = ec.each_index.uniq { |byte| ec.fetch(byte) }
        left_context = terms.compile_left_context(ec, representatives, &state_limit)
        if terms.left_sensitive
          contexts = left_context ? left_context.transitions.each_index : LeftContext::STATES
          states = contexts.map do |left|
            vector = terms.context_kind(left) == LeftContext::OTHER ? start.reject { |pattern, _| conditions.fetch(pattern).bol_only }.freeze : start
            [vector, left]
          end
          starts = states.each_index.to_a
          starts.drop(1).each { |state| state_limit.call(state, operation) }
        else
          states = [start]
        end
        ids = states.each_with_index.to_h
        transitions = []
        accepts = []

        index = 0
        while index < states.length
          vector, left = states.fetch(index)
          accepts << terms.accepting_conditions(vector, conditions, ec: ec, representatives: representatives,
                                               left: left, &state_limit)
          transitions << representatives.each_with_index.map do |byte, class_id|
            successor = advance(vector, terms, byte, class_id, left)
            next if successor.empty?

            successor = [successor, terms.next_left(left, byte)] if left
            ids[successor] ||= begin
              state_limit.call(states.length, operation)
              states.push(successor).length - 1
            end
          end
          index += 1
        end

        dfa = DFA.new(transitions: transitions, accepts: accepts, ec: ec, class_count: count,
                      start: 0, starts: starts, left_context: left_context, rule_ids: accepts.flatten.map(&:rule_index))
        return dfa unless minimize
        return Minimizer.minimize(dfa) unless retain_residuals

        Minimizer.minimize(dfa) do |representatives|
          vectors = representatives.map do |state|
            vector = states.fetch(state)
            starts ? vector.first : vector
          end
          @residuals = DerivativeResiduals.new(terms.expressions, vectors, conditions)
        end
      end

      private

      def advance(vector, terms, byte, class_id, left)
        vector.each_with_object({}) do |(pattern, term), residuals|
          residual = terms.derivative(term, byte, class_id, left)
          residuals[pattern] = residual unless residual == DerivativeTerms::FAIL
        end.freeze
      end
    end
  end
end
