# frozen_string_literal: true

require_relative "derivative_terms"
require_relative "derivative_residuals"

module Flexr
  module Automaton
    class DerivativeCompiler
      attr_reader :residuals

      def compile(patterns, retain_residuals: false, minimize: true, lazy: false, &state_limit)
        @residuals = nil
        terms = DerivativeTerms.new
        start = patterns.each_with_index.to_h { |(body, _), index| [index, terms.from_ast(body)] }.freeze
        conditions = patterns.map(&:last)
        operation = terms.operations.join(" and ") unless terms.operations.empty?
        ec, count = terms.byte_classes.build
        if lazy
          require_relative "lazy_derivative_dfa"
          return LazyDerivativeDFA.new(start, conditions, terms, ec, count) do |size|
            state_limit.call(size, operation)
          end
        end

        representatives = ec.each_index.uniq { |byte| ec.fetch(byte) }
        states = [start]
        ids = { start => 0 }
        transitions = []
        accepts = []

        index = 0
        while index < states.length
          vector = states.fetch(index)
          accepts << vector.filter_map { |pattern, term| conditions.fetch(pattern) if terms.nullable?(term) }.uniq
          transitions << representatives.each_with_index.map do |byte, class_id|
            successor = terms.advance(vector, byte, class_id)
            next if successor.empty?

            ids[successor] ||= begin
              state_limit.call(states.length, operation)
              states.push(successor).length - 1
            end
          end
          index += 1
        end

        dfa = DFA.new(transitions: transitions, accepts: accepts, ec: ec, class_count: count,
                      start: 0, rule_ids: accepts.flatten.map(&:rule_index))
        return dfa unless minimize
        return Minimizer.minimize(dfa) unless retain_residuals

        Minimizer.minimize(dfa) do |representatives|
          vectors = representatives.map { |state| states.fetch(state) }
          @residuals = DerivativeResiduals.new(terms.expressions, vectors, conditions)
        end
      end

    end
  end
end
