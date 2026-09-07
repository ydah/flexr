# frozen_string_literal: true

module Flexr
  module Unicode
    module ReferenceRegexp
      # rubocop:disable-next Style/MutableConstant
      CACHE = {}
      module_function

      def match(pattern, subject, encoding:, options: 0, unicode: false)
        regexp = compiled(pattern, encoding: encoding, options: options, unicode: unicode)
        subject = subject.dup.force_encoding(regexp.encoding)
        regexp.match(subject, 0)
      rescue RegexpError, ArgumentError, EncodingError
        nil
      end

      def compiled(pattern, encoding:, options: nil, unicode: false)
        effective_options = options.nil? ? pattern.options : options
        key = [pattern.source, effective_options, encoding, unicode]
        return CACHE[key] if CACHE.key?(key)

        parser = Regexp::Parser.new(pattern.source, options: effective_options, encoding: encoding, unicode: unicode)
        source = source_for(parser.parse)
        regexp_options = effective_options & ~::Regexp::IGNORECASE
        CACHE[key] = ::Regexp.new(source, regexp_options).freeze
      end

      def source_for(node)
        case node
        when Regexp::AST::Empty, Regexp::AST::Anchor then ""
        when Regexp::AST::Fail then "(?!)"
        when Regexp::AST::ByteRange then byte_class([[node.lo, node.hi]])
        when Regexp::AST::CodepointRange then codepoint_class([[node.lo, node.hi]])
        when Regexp::AST::CharClass
          ranges = node.ranges.flat_map do |range|
            if range.first == Regexp::AST::Property
              property_ranges = Unicode::Property.ranges(range[2])
              property_ranges = casefold_ranges(property_ranges) if range[3]
              range[1] ? complement(property_ranges) : property_ranges
            else
              [range]
            end
          end
          ranges = complement(ranges) if node.negated
          codepoint_class(ranges)
        when Regexp::AST::Seq then node.children.map { |child| source_for(child) }.join
        when Regexp::AST::Alt
          "(?:#{node.children.map { |child| source_for(child) }.join('|')})"
        when Regexp::AST::Star then "(?:#{source_for(node.child)})*"
        when Regexp::AST::Repeat
          maximum = node.maximum.nil? ? "" : node.maximum
          "(?:#{source_for(node.child)}){#{node.minimum},#{maximum}}"
        else
          raise CompileError, "unsupported reference AST node: #{node.class}"
        end
      end

      def byte_class(ranges)
        "[#{ranges.map { |lo, hi| byte_escape(lo, hi) }.join}]"
      end

      def byte_escape(lo, hi)
        lo == hi ? format("\\x%<byte>02X", byte: lo) : format("\\x%<lo>02X-\\x%<hi>02X", lo: lo, hi: hi)
      end

      def codepoint_class(ranges)
        ranges = scalar_ranges(ranges)
        return "(?!)" if ranges.empty?

        "[#{ranges.sort_by(&:first).map { |lo, hi| codepoint_escape(lo, hi) }.join}]"
      end

      def scalar_ranges(ranges)
        ranges.flat_map do |lo, hi|
          result = []
          result << [lo, [hi, 0xd7ff].min] if lo <= 0xd7ff
          result << [[lo, 0xe000].max, hi] if hi >= 0xe000
          result
        end
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

      def casefold_ranges(ranges)
        CaseFold.merge(ranges.flat_map { |lo, hi| CaseFold.ranges(lo, hi) })
      end
    end
  end
end
