# frozen_string_literal: true

# shortcut: Standalone lexers embed the scanner. Enable proofs when the compiler can load alongside it.
raise LoadError, "language assertions require the Flexr compiler" unless Flexr.respond_to?(:compile_pattern)

require_relative "../source/semantic_diff"

module Flexr
  module Testing
    module Languages
      SEARCH_LIMIT = 100_000
      Assertion = Data.define(:status, :expectation, :negation, :detail) do
        def failure_message(negated: false)
          return negation if negated && status != :inconclusive

          message = negated ? negation : expectation
          detail ? "#{message}\n#{detail}" : message
        end
      end

      private_constant :SEARCH_LIMIT, :Assertion
      module_function

      def disjoint_tokens(lexer, first, second, state: :initial)
        state = state_name(state)
        input = Source::SemanticDiff::Input.from_lexer(lexer, ordered: false)
        raise ArgumentError, "unknown lexer state #{state.inspect}" unless input.compiled.machines.key?(state)

        tokens = [first, second]
        validate_tokens(lexer, input, tokens)
        result = Automaton::TokenDiff.overlap(input.side(state, ordered: false), tokens: tokens, encoding: input.encoding, limit: SEARCH_LIMIT)
        if result.input
          length = result.left.length
          lexeme = result.input.byteslice(result.offset, length)
          detail = "#{witness(result)}, shared lexeme #{lexeme.inspect} (#{byte_length(length)})"
        end
        context = "#{first.inspect} and #{second.inspect} in state #{state.inspect}"
        assertion(result, "expected #{lexer} to have disjoint token languages for #{context}",
                  "expected #{lexer} to have overlapping token languages for #{context}", detail)
      end

      def include_language(superset, subset, encoding: Encoding::UTF_8, unicode: false)
        encoding = Configuration.encoding!(encoding)
        options = { allow_empty_match: true, unicode: unicode }
        left, right = [superset, subset].map { |pattern| compile_pattern(pattern, encoding, options) }
        result = Automaton::TokenDiff.inclusion(left, right, encoding: encoding, limit: SEARCH_LIMIT)
        detail = "#{witness(result)} is accepted by #{subset.inspect} but rejected by #{superset.inspect}" if result.input
        assertion(result, "expected #{superset.inspect} to include the language of #{subset.inspect}",
                  "expected #{superset.inspect} to exclude some input accepted by #{subset.inspect}", detail)
      end

      def tokenize_like(actual, expected, state: :initial)
        state = state_name(state)
        left, right = [expected, actual].map { |lexer| Source::SemanticDiff::Input.from_lexer(lexer) }
        raise ArgumentError, "unknown lexer state #{state.inspect}" unless
          left.compiled.machines.key?(state) || right.compiled.machines.key?(state)

        result = Source::SemanticDiff.new(left, right, limit: SEARCH_LIMIT).states([state]).first.result
        detail = "#{witness(result)}\n  expected selection #{selection(result.left)}\n  actual selection #{selection(result.right)}" if result.input
        assertion(result, "expected #{actual} to tokenize like #{expected} in state #{state.inspect}",
                  "expected #{actual} to tokenize differently from #{expected} in state #{state.inspect}", detail)
      end

      def assertion(result, expectation, negation, detail)
        detail = "comparison inconclusive: #{result.reason}" if result.status == :inconclusive
        Assertion.new(status: result.status, expectation: expectation, negation: negation, detail: detail || result.reason)
      end

      def state_name(state)
        raise ArgumentError, "lexer state must be a Symbol or String" unless state.is_a?(Symbol) || state.is_a?(String)

        state.to_sym
      end

      def validate_tokens(lexer, input, tokens)
        raise ArgumentError, "expected two distinct token Symbols" unless tokens.uniq.length == 2 && tokens.all?(Symbol)

        known = lexer.__flexr_config.declared_tokens + input.rules.flat_map do |rule|
          rule.emit? ? [rule.action[1]] : Array(rule.emits)
        end
        missing = tokens - known
        raise ArgumentError, "unknown token #{missing.map(&:inspect).join(', ')}" unless missing.empty?
      end

      def compile_pattern(pattern, encoding, options)
        pattern = Pattern.build(pattern) if pattern.is_a?(String)
        raise ArgumentError, "expected a Pattern, Regexp, or String" unless pattern.is_a?(Pattern) || pattern.is_a?(::Regexp)

        Flexr.compile_pattern(pattern, encoding: encoding, options: options)
      end

      def witness(result)
        "counterexample #{result.input.inspect} at byte #{result.offset}"
      end

      def selection(match)
        return "no match" unless match

        effect = match.effect
        action = case effect&.action
        when :emit then effect.token.inspect
        when :skip then "skip"
        else "opaque action"
        end
        description = "#{action} (#{byte_length(match.length)}, rule #{match.rule_index})"
        description += " on channel #{effect.channel.inspect}" if effect&.channel
        description += " with state operations #{effect.state_operations.inspect}" if effect && !effect.state_operations.empty?
        description
      end

      def byte_length(length)
        length == 1 ? "1 byte" : "#{length} bytes"
      end

      private_class_method :assertion, :state_name, :validate_tokens, :compile_pattern, :witness, :selection, :byte_length
    end
  end
end
