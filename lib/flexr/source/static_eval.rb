# frozen_string_literal: true

module Flexr
  module Source
    class StaticEval
      attr_reader :constants

      def initialize(source, constants: {})
        @source = source
        @constants = constants
      end

      def call(node)
        evaluate(node)
      rescue StaticResolutionError
        raise
      rescue StandardError => error
        raise_resolution("#{node.class}: #{error.message}")
      end

      private

      def evaluate(node)
        kind = node.class.name.split("::").last
        case kind
        when "RegularExpressionNode"
          ::Regexp.new(node.unescaped, node.options)
        when "InterpolatedRegularExpressionNode"
          ::Regexp.new(interpolated(node.parts), node.options)
        when "StringNode"
          node.unescaped
        when "InterpolatedStringNode"
          interpolated(node.parts)
        when "SymbolNode"
          node.unescaped.to_sym
        when "IntegerNode"
          node.value
        when "FloatNode"
          node.value
        when "TrueNode"
          true
        when "FalseNode"
          false
        when "NilNode"
          nil
        when "ArrayNode"
          node.elements.map { |element| evaluate(element) }
        when "ConstantReadNode"
          @constants.fetch(node.name) { raise_resolution("constant #{node.name} is not statically known") }
        when "ConstantPathNode"
          evaluate_constant_path(node)
        when "SplatNode"
          evaluate(node.expression)
        when "RangeNode"
          Range.new(evaluate(node.left), evaluate(node.right), node.exclude_end?)
        when "CallNode"
          evaluate_call(node)
        else
          raise_resolution("expression #{kind} is not statically supported")
        end
      end

      def interpolated(parts)
        parts.map do |part|
          kind = part.class.name.split("::").last
          if kind == "EmbeddedStatementsNode"
            body = part.statements&.body || []
            value = evaluate(body.last)
            value.is_a?(::Regexp) ? "(?:#{value.source})" : value.to_s
          else
            evaluate(part).to_s
          end
        end.join
      end

      def evaluate_constant_path(node)
        name = if node.respond_to?(:name)
          node.name
        else
          node.child.name
        end
        return Encoding.const_get(name) if node.respond_to?(:parent) && node.parent&.name == :Encoding

        raise_resolution("constant path is not statically supported")
      end

      def evaluate_call(node)
        if node.receiver && node.name == :freeze
          return evaluate(node.receiver).freeze
        end
        if node.receiver && node.name == :union && constant_name(node.receiver) == "Regexp"
          return ::Regexp.union(positional_arguments(node).map { |argument| evaluate(argument) })
        end
        raise_resolution("method call #{node.name} is not statically supported")
      end

      def positional_arguments(node)
        Array(node.arguments&.arguments).reject { |argument| argument.class.name.end_with?("KeywordHashNode") }
      end

      def constant_name(node)
        return node.name.to_s if node.respond_to?(:name)

        nil
      end

      def raise_resolution(reason)
        diagnostic = Diagnostics.error(
          "FLEXR-E017", "pattern is not statically resolvable",
          help: "pass a literal, a constant, or use --eval",
          note: "#{reason}; runtime mode still supports this Ruby expression"
        )
        raise StaticResolutionError.new(diagnostic.message, diagnostic: diagnostic)
      end
    end
  end
end
