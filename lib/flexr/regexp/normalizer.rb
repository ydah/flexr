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
          byte_sequences_for_ranges(casefold_ranges(node.lo, node.hi))
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
        byte_sequences_for_ranges(ranges)
      end

      def byte_sequences_for_ranges(ranges)
        if @byte_mode
          byte_ranges = ranges.filter_map do |lo, hi|
            next if lo > 255

            [lo, [hi, 255].min]
          end
          return AST::Empty.new(loc: nil) if byte_ranges.empty?

          return alternatives(byte_ranges.map { |lo, hi| AST::ByteRange.new(lo: lo, hi: hi, loc: nil) })
        end

        sequences = ranges.flat_map { |lo, hi| Unicode::Utf8Splitter.split(lo, hi) }
        trie(sequences, 0)
      end

      def trie(sequences, index)
        return AST::Empty.new(loc: nil) if sequences.empty?
        return AST::Empty.new(loc: nil) if sequences.first.length == index

        groups = sequences.group_by { |sequence| sequence[index] }
        alternatives(groups.map do |(lo, hi), group|
          child = trie(group, index + 1)
          AST::Seq.new(children: [AST::ByteRange.new(lo: lo, hi: hi, loc: nil), child], loc: nil)
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
        return [[lo, hi]] if @options.nobits?(::Regexp::IGNORECASE)
        Unicode::CaseFold.ranges(lo, hi)
      end
    end
  end
end
