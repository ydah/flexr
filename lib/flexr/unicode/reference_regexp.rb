# frozen_string_literal: true

module Flexr
  module Unicode
    module ReferenceRegexp
      CACHE = {} # rubocop:disable Style/MutableConstant
      module_function

      def match(pattern, subject, encoding:, options: 0, unicode: false)
        regexp = compiled(pattern, encoding: encoding, options: options, unicode: unicode)
        subject = subject.dup.force_encoding(regexp.encoding)
        regexp.match(subject, 0)
      rescue RegexpError, ArgumentError, EncodingError
        nil
      end

      def compiled(pattern, encoding:, options: nil, unicode: false, anchored: false, following_lf: false, invalid_eof: false, invalid_left: false, invalid_tail_marker: false)
        effective_options = options.nil? ? pattern.options : options
        key = [pattern.source, effective_options, encoding, unicode, anchored, following_lf, invalid_eof, invalid_left, invalid_tail_marker]
        return CACHE[key] if CACHE.key?(key)

        captures = !pattern.names.empty?
        binary = captures && encoding == Encoding::BINARY
        parser = Regexp::Parser.new(pattern.source, options: effective_options, encoding: encoding, unicode: unicode,
                                   preserve_captures: captures)
        ast = parser.parse
        if invalid_eof && !invalid_tail_marker
          Regexp::AST.anchors(ast).each do |anchor|
            anchor.kind = :before_lf if anchor.kind == :line_end
            anchor.kind = :line_start_before_invalid if anchor.kind == :line_start
            anchor.kind = :never if %i[eof final_eol].include?(anchor.kind)
          end
        end
        source = source_for(ast, binary: binary, invalid_left: invalid_left, invalid_tail_marker: invalid_tail_marker)
        if anchored
          ending = following_lf ? '(?=\n\z)' : '\z'
          source = "\\A(?:#{source})#{ending}"
        end
        regexp_options = effective_options & ~::Regexp::IGNORECASE
        regexp_options |= ::Regexp::NOENCODING if binary
        CACHE[key] = ::Regexp.new(source, regexp_options).freeze
      end

      def source_for(node, binary: false, invalid_left: false, invalid_tail_marker: false)
        if invalid_tail_marker && (node.is_a?(Regexp::AST::ByteRange) || node.is_a?(Regexp::AST::CodepointRange) ||
                                  node.is_a?(Regexp::AST::CharClass))
          return "(?!(?m:.\\z))#{source_for(node, binary: binary)}"
        end

        case node
        when Regexp::AST::Empty then ""
        when Regexp::AST::Anchor then anchor_source(node.kind)
        when Regexp::AST::Fail then "(?!)"
        when Regexp::AST::NotNextLineFeed then '(?!\n)'
        when Regexp::AST::Lookbehind
          branches = node.child.is_a?(Regexp::AST::Alt) ? node.child.children : [node.child]
          source = branches.map do |child|
            body = source_for(child, binary: binary, invalid_left: invalid_left)
            invalid_left ? "(?<!\\A)#{body}" : body
          end.join("|")
          "(?<#{node.negative ? '!' : '='}#{source})"
        when Regexp::AST::Lookahead
          "(?#{node.negative ? '!' : '='}#{source_for(node.child, binary: binary, invalid_left: invalid_left, invalid_tail_marker: invalid_tail_marker)})"
        when Regexp::AST::ByteRange then byte_class([[node.lo, node.hi]])
        when Regexp::AST::CodepointRange then character_class([[node.lo, node.hi]], binary: binary)
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
          character_class(ranges, binary: binary)
        when Regexp::AST::Seq then node.children.map { |child| source_for(child, binary: binary, invalid_left: invalid_left, invalid_tail_marker: invalid_tail_marker) }.join
        when Regexp::AST::Alt
          "(?:#{node.children.map { |child| source_for(child, binary: binary, invalid_left: invalid_left, invalid_tail_marker: invalid_tail_marker) }.join('|')})"
        when Regexp::AST::Star then "(?:#{source_for(node.child, binary: binary, invalid_left: invalid_left, invalid_tail_marker: invalid_tail_marker)})*"
        when Regexp::AST::Repeat
          maximum = node.maximum.nil? ? "" : node.maximum
          "(?:#{source_for(node.child, binary: binary, invalid_left: invalid_left, invalid_tail_marker: invalid_tail_marker)}){#{node.minimum},#{maximum}}"
        when Regexp::AST::NamedCapture then "(?#{node.opening}#{source_for(node.child, binary: binary, invalid_left: invalid_left, invalid_tail_marker: invalid_tail_marker)})"
        when Regexp::AST::Absence
          child = source_for(node.child, binary: binary, invalid_left: invalid_left, invalid_tail_marker: invalid_tail_marker)
          return "(?:(?!)#{child})" if Regexp::AST.nullable?(node.child) && !Regexp::AST.contextual?(node.child)

          child = "(?:#{child})|(?m:.\\z)" if invalid_tail_marker
          "(?~(?:#{child}))"
        else
          raise CompileError, "unsupported reference AST node: #{node.class}"
        end
      end

      def anchor_source(kind)
        case kind
        when :source_start then '\A'
        when :line_start then "^"
        when :line_start_before_invalid then '(?:^|(?<=\n)\z)'
        when :line_end then "$"
        when :eof then '\z'
        when :final_eol then '\Z'
        when :before_lf then '(?=\n)'
        when :never then "(?!)"
        else ""
        end
      end

      def character_class(ranges, binary:)
        return codepoint_class(ranges) unless binary

        bytes = ranges.filter_map { |lo, hi| [lo, [hi, 255].min] if lo <= 255 }
        bytes.empty? ? "(?!)" : byte_class(bytes)
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
