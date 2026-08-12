# frozen_string_literal: true

module Flexr
  module Source
    class StaticEval
      MISSING = Object.new.freeze

      attr_reader :constants

      def initialize(source, constants: {}, scope: [])
        @source = source
        @constants = constants
        @scope = Array(scope).map(&:to_s)
      end

      def call(node)
        evaluate(node)
      rescue StaticResolutionError
        raise
      rescue StandardError => e
        raise_resolution("#{node.class}: #{e.message}")
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
        when "IntegerNode", "FloatNode"
          node.value
        when "TrueNode"
          true
        when "FalseNode"
          false
        when "NilNode"
          nil
        when "ArrayNode"
          node.elements.flat_map do |element|
            if element.class.name.end_with?("SplatNode")
              Array(evaluate(element.expression))
            else
              [evaluate(element)]
            end
          end
        when "HashNode"
          evaluate_hash(node)
        when "ConstantReadNode"
          evaluate_constant([node.name.to_s], absolute: false)
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
            raise_resolution("interpolation must contain exactly one expression") unless body.one?

            value = evaluate(body.first)
            value.is_a?(::Regexp) ? regexp_fragment(value) : value.to_s
          else
            evaluate(part).to_s
          end
        end.join
      end

      def evaluate_constant_path(node)
        source = source_slice(node)
        absolute = source.start_with?("::")
        parts = source.delete_prefix("::").split("::").reject(&:empty?)
        evaluate_constant(parts, absolute: absolute)
      end

      def evaluate_constant(parts, absolute:)
        candidates = if absolute
          [parts.join("::")]
        else
          @scope.length.downto(0).map do |depth|
            (@scope.take(depth) + parts).join("::")
          end
        end

        candidates.uniq.each do |candidate|
          value = constant_value(candidate)
          return value unless value.equal?(MISSING)
        end

        return ::Encoding.const_get(parts.last) if parts.length == 2 && parts.first == "Encoding"

        raise_resolution("constant #{parts.join('::')} is not statically known")
      rescue NameError
        raise_resolution("constant #{parts.join('::')} is not statically known")
      end

      def constant_value(name)
        return @constants[name] if @constants.key?(name)

        symbol = name.to_sym
        return @constants[symbol] if @constants.key?(symbol)

        MISSING
      end

      def source_slice(node)
        location = node.location
        @source.byteslice(location.start_offset...location.end_offset)
      end

      def evaluate_call(node)
        return evaluate(node.receiver).freeze if node.receiver && node.name == :freeze
        return ::Regexp.union(positional_arguments(node).map { |argument| evaluate(argument) }) if node.receiver && node.name == :union && constant_name(node.receiver) == "Regexp"
        raise_resolution("method call #{node.name} is not statically supported")
      end

      def evaluate_hash(node)
        node.elements.each_with_object({}) do |element, result|
          kind = element.class.name.split("::").last
          if kind == "AssocNode"
            result[evaluate(element.key)] = evaluate(element.value)
          elsif kind == "AssocSplatNode"
            value = evaluate(element.value)
            raise_resolution("hash splat value must be a Hash") unless value.is_a?(Hash)

            result.merge!(value)
          else
            raise_resolution("hash element #{kind} is not statically supported")
          end
        end
      end

      def regexp_fragment(regexp)
        flags = {
          "i" => ::Regexp::IGNORECASE,
          "m" => ::Regexp::MULTILINE,
          "x" => ::Regexp::EXTENDED
        }
        enabled, disabled = flags.partition { |_name, bit| regexp.options.anybits?(bit) }
        "(?#{enabled.to_h.keys.join}-#{disabled.to_h.keys.join}:#{regexp.source})"
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
          note: "#{reason}; runtime mode still supports this Ruby expression; --eval can resolve it by executing the spec"
        )
        raise StaticResolutionError.new(diagnostic.message, diagnostic: diagnostic)
      end
    end
  end
end
