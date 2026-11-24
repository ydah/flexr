# frozen_string_literal: true

module Flexr
  module Automaton
    class DerivativeResiduals
      def initialize(expressions, vectors, conditions)
        @expressions = expressions.freeze
        @vectors = vectors.freeze
        @patterns = conditions.map { |entry| [entry.rule_index, entry.pattern_index].freeze }.freeze
        freeze
      end

      def describe(state, rule: nil)
        @vectors.fetch(state).filter_map do |index, term|
          rule_index, pattern = @patterns.fetch(index)
          next if (!rule.nil? && rule_index != rule) || term == DerivativeTerms::FAIL

          { rule: rule_index, pattern: pattern, expression: expression(term) }
        end
      end

      def self.render(entries)
        entries.map do |entry|
          "rule #{entry.fetch(:rule)} pattern #{entry.fetch(:pattern)}: #{entry.fetch(:expression)}"
        end.join(", ")
      end

      private

      def expression(term)
        kind, *parts = @expressions.fetch(term)
        case kind
        when :empty then "ε"
        when :fail then "∅"
        when :guard then "(?=#{expression(parts.first)})#{expression(parts.last)}"
        when :first_ending then "first_ending(#{expression(parts.first)})"
        when :prefix then "prefix(#{expression(parts.first)})"
        when :suffix_graph then "lookahead[#{parts.first}][#{parts.last}]"
        when :byte then byte_range(*parts)
        when :sequence then parts.map { |part| expression(part) }.join
        when :union then "(?:#{parts.map { |part| expression(part) }.join('|')})"
        when :intersection then "(#{parts.map { |part| expression(part) }.join(' & ')})"
        when :negate then "¬(#{expression(parts.first)})"
        when :repeat then repetition(*parts)
        when :graph then "DFA[#{parts.fetch(0)}][#{parts.fetch(1)}]"
        end
      end

      def repetition(term, minimum, maximum)
        child = expression(term)
        child = "(?:#{child})" if %i[sequence repeat].include?(@expressions.fetch(term).first)
        suffix = case [minimum, maximum]
        when [0, nil] then "*"
        when [1, nil] then "+"
        when [0, 1] then "?"
        else
          minimum == maximum ? "{#{minimum}}" : "{#{minimum},#{maximum}}"
        end
        "#{child}#{suffix}"
      end

      def byte_range(lo, hi)
        return byte(lo) if lo == hi

        "[#{byte(lo)}-#{byte(hi)}]"
      end

      def byte(value)
        value.between?(0x21, 0x7e) ? ::Regexp.escape(value.chr) : format("\\x%02X", value)
      end
    end
  end
end
