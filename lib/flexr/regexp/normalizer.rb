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
        when AST::Empty, AST::Fail, AST::ByteRange, AST::CodepointRange, AST::Anchor
          normalize_leaf(node)
        when AST::CharClass
          char_class(node)
        when AST::Seq
          sequence(node.children.map { |child| normalize_node(child) })
        when AST::Alt
          alternatives(node.children.map { |child| normalize_node(child) })
        when AST::Star
          child = normalize_node(node.child)
          child.is_a?(AST::Fail) ? AST::Empty.new(loc: node.loc) : AST::Star.new(child: child, loc: node.loc)
        when AST::Repeat
          repeat(node)
        else
          raise CompileError, "unknown regexp AST node: #{node.class}"
        end
      end

      def normalize_leaf(node)
        case node
        when AST::CodepointRange
          byte_sequences_for_ranges([[node.lo, node.hi]], loc: node.loc)
        else
          node
        end
      end

      def char_class(node)
        ranges = node.ranges.flat_map do |range|
          if range.first == AST::Property
            property_ranges = Unicode::Property.ranges(range[2])
            property_ranges = property_ranges.flat_map { |lo, hi| Unicode::CaseFold.ranges(lo, hi) } if range[3]
            range[1] ? complement(property_ranges) : property_ranges
          else
            [range]
          end
        end
        ranges = complement(ranges) if node.negated
        byte_sequences_for_ranges(ranges, loc: node.loc)
      end

      def byte_sequences_for_ranges(ranges, loc:)
        if @byte_mode
          byte_ranges = ranges.filter_map do |lo, hi|
            next if lo > 255

            [lo, [hi, 255].min]
          end
          return AST::Fail.new(loc: loc) if byte_ranges.empty?

          return alternatives(byte_ranges.map { |lo, hi| AST::ByteRange.new(lo: lo, hi: hi, loc: loc) })
        end

        sequences = ranges.flat_map { |lo, hi| Unicode::Utf8Splitter.split(lo, hi) }
        @trie_cache = {}
        trie(sequences, 0)
      end

      def trie(sequences, index)
        return AST::Fail.new(loc: nil) if sequences.empty?

        finished, continuing = sequences.partition { |sequence| sequence.length == index }
        nodes = []
        nodes << AST::Empty.new(loc: nil) unless finished.empty?
        return nodes.first if continuing.empty?

        key = [index, continuing]
        return alternatives(nodes + [@trie_cache[key]]) if @trie_cache.key?(key)

        endpoints = continuing.flat_map do |sequence|
          lo, hi = sequence.fetch(index)
          [lo, hi + 1]
        end.uniq.sort
        partitions = endpoints.each_cons(2).filter_map do |lo, after_hi|
          covered = continuing.select do |sequence|
            range = sequence.fetch(index)
            range.first <= lo && range.last >= after_hi - 1
          end
          [lo, after_hi - 1, covered] unless covered.empty?
        end
        branches = partitions.map { |lo, hi, covered| [lo, hi, trie(covered, index + 1)] }
        merged = branches.each_with_object([]) do |(lo, hi, child), result|
          if !result.empty? && result.last[1] + 1 == lo && result.last[2] == child
            result.last[1] = hi
          else
            result << [lo, hi, child]
          end
        end
        tree = alternatives(merged.map do |lo, hi, child|
          sequence([AST::ByteRange.new(lo: lo, hi: hi, loc: nil), child])
        end)
        @trie_cache[key] = tree
        alternatives(nodes + [tree])
      end

      def sequence(children)
        flattened = children.flat_map { |child| child.is_a?(AST::Seq) ? child.children : [child] }
        return AST::Fail.new(loc: nil) if flattened.any?(AST::Fail)

        flattened.reject! { |child| child.is_a?(AST::Empty) }
        return AST::Empty.new(loc: nil) if flattened.empty?
        return flattened.first if flattened.length == 1

        AST::Seq.new(children: flattened, loc: nil)
      end

      def alternatives(children)
        flattened = children.flat_map { |child| child.is_a?(AST::Alt) ? child.children : [child] }
        flattened.reject! { |child| child.is_a?(AST::Fail) }
        flattened.uniq!
        return AST::Fail.new(loc: nil) if flattened.empty?
        return flattened.first if flattened.length == 1

        AST::Alt.new(children: flattened, loc: nil)
      end

      def repeat(node)
        child = normalize_node(node.child)
        return AST::Empty.new(loc: node.loc) if node.maximum&.zero? || child.is_a?(AST::Empty)
        return node.minimum.zero? ? AST::Empty.new(loc: node.loc) : AST::Fail.new(loc: node.loc) if
          child.is_a?(AST::Fail)

        AST::Repeat.new(child: child, minimum: node.minimum, maximum: node.maximum, loc: node.loc)
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

    end
  end
end
