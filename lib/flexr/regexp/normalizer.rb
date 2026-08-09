# frozen_string_literal: true

module Flexr
  module Regexp
    class Normalizer
      def initialize(ast, encoding: Encoding::UTF_8, options: 0)
        @ast = ast
        @encoding = encoding
        @options = options
        @byte_mode = [Encoding::BINARY, Encoding::US_ASCII].include?(encoding)
      end

      def normalize
        normalize_node(@ast)
      end

      private

      def normalize_node(node)
        case node
        when AST::Empty, AST::ByteRange, AST::CodepointRange, AST::Anchor
          normalize_leaf(node)
        when AST::CharClass
          char_class(node)
        when AST::Seq
          sequence(node.children.map { |child| normalize_node(child) })
        when AST::Alt
          alternatives(node.children.map { |child| normalize_node(child) })
        when AST::Star
          AST::Star.new(child: normalize_node(node.child), loc: node.loc)
        else
          raise CompileError, "unknown regexp AST node: #{node.class}"
        end
      end

      def normalize_leaf(node)
        case node
        when AST::CodepointRange
          alternatives(casefold_ranges(node.lo, node.hi).flat_map do |lo, hi|
            value = byte_sequences(lo, hi)
            value.is_a?(AST::Alt) ? value.children : [value]
          end)
        else
          node
        end
      end

      def char_class(node)
        ranges = node.ranges.flat_map do |range|
          if range.first == AST::Property
            Unicode::Property.ranges(range.last, negate: range[1])
          else
            casefold_ranges(*range)
          end
        end
        ranges = complement(ranges) if node.negated
        alternatives(ranges.flat_map { |lo, hi| byte_sequences(lo, hi) })
      end

      def byte_sequences(lo, hi)
        if @byte_mode
          return AST::Empty.new(loc: nil) if lo > 255
          hi = 255 if hi > 255
          return AST::ByteRange.new(lo: lo, hi: hi, loc: nil) if lo <= hi
        end

        sequences = Unicode::Utf8Splitter.split(lo, hi)
        alternatives(sequences.map do |sequence|
          AST::Seq.new(children: sequence.map { |range| AST::ByteRange.new(lo: range[0], hi: range[1], loc: nil) }, loc: nil)
        end)
      end

      def sequence(children)
        flattened = children.flat_map { |child| child.is_a?(AST::Seq) ? child.children : [child] }
        return AST::Empty.new(loc: nil) if flattened.empty?
        return flattened.first if flattened.length == 1

        AST::Seq.new(children: flattened, loc: nil)
      end

      def alternatives(children)
        flattened = children.flat_map { |child| child.is_a?(AST::Alt) ? child.children : [child] }
        return AST::Empty.new(loc: nil) if flattened.empty?
        return flattened.first if flattened.length == 1

        AST::Alt.new(children: flattened, loc: nil)
      end

      def complement(ranges)
        result = []
        cursor = 0
        ranges.sort_by(&:first).each do |lo, hi|
          result << [cursor, lo - 1] if cursor < lo
          cursor = [cursor, hi + 1].max
        end
        result << [cursor, 0x10ffff] if cursor <= 0x10ffff
        result
      end

      def casefold_ranges(lo, hi)
        return [[lo, hi]] if (@options & ::Regexp::IGNORECASE).zero?
        return [[lo, hi]] unless lo <= 0x7f && hi >= 0

        points = (lo..hi).to_a
        points.concat(points.filter_map do |codepoint|
          char = codepoint.chr(Encoding::UTF_8)
          folded = char.swapcase.ord
          folded <= 0x7f ? folded : nil
        end)
        points.sort.each_with_object([]) do |point, result|
          if result.empty? || point > result.last.last + 1
            result << [point, point]
          else
            result.last[1] = point
          end
        end
      end
    end
  end
end
