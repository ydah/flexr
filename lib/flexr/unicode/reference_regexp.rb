# frozen_string_literal: true

module Flexr
  module Unicode
    module ReferenceRegexp
      CACHE = {}
      module_function

      def match(pattern, subject, encoding:, options: 0, unicode: false)
        regexp = compiled(pattern, encoding: encoding, options: options, unicode: unicode)
        regexp.match(subject, 0)
      rescue RegexpError, ArgumentError
        nil
      end

      def compiled(pattern, encoding:, options: 0, unicode: false)
        key = [pattern.source, pattern.options, encoding, unicode]
        return CACHE[key] if CACHE.key?(key)

        parser = Regexp::Parser.new(pattern.source, options: pattern.options, encoding: encoding, unicode: unicode)
        source = source_for(parser.parse)
        regexp_options = options & ~::Regexp::IGNORECASE
        CACHE[key] = ::Regexp.new(source, regexp_options).freeze
      end

      def source_for(node)
        case node
        when Regexp::AST::Empty then ""
        when Regexp::AST::ByteRange then byte_class([[node.lo, node.hi]])
        when Regexp::AST::CodepointRange then codepoint_class([[node.lo, node.hi]])
        when Regexp::AST::CharClass
          ranges = node.ranges.flat_map do |range|
            if range.first == Regexp::AST::Property
              Unicode::Property.ranges(range[2], negate: range[1])
            else
              [range]
            end
          end
          ranges = complement(ranges) if node.negated
          codepoint_class(ranges)
        when Regexp::AST::Seq then node.children.map { |child| source_for(child) }.join
        when Regexp::AST::Alt then "(?:#{node.children.map { |child| source_for(child) }.join('|')})"
        when Regexp::AST::Star then "(?:#{source_for(node.child)})*"
        when Regexp::AST::Anchor then ""
        else
          raise CompileError, "unsupported reference AST node: #{node.class}"
        end
      end

      def byte_class(ranges)
        "[#{ranges.map { |lo, hi| byte_escape(lo, hi) }.join}]"
      end

      def byte_escape(lo, hi)
        lo == hi ? "\\x%02X" % lo : "\\x%02X-\\x%02X" % [lo, hi]
      end

      def codepoint_class(ranges)
        "[#{ranges.sort_by(&:first).map { |lo, hi| codepoint_escape(lo, hi) }.join}]"
      end

      def codepoint_escape(lo, hi)
        first = ::Regexp.escape([lo].pack("U"))
        last = ::Regexp.escape([hi].pack("U"))
        lo == hi ? first : "#{first}-#{last}"
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
