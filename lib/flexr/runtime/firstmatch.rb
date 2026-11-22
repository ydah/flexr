# frozen_string_literal: true

module Flexr
  module Runtime
    module Firstmatch
      private

      def reference_pattern?(pattern)
        Regexp::Matcher.reference?(pattern, encoding: @config.encoding, unicode: @config.options[:unicode] == true)
      end

      def scan_firstmatch(position)
        buffer = @lexer.buffer
        @rules.sort_by(&:index).each do |rule|
          next unless rule_active?(rule)

          matches = rule.patterns.each_with_index.filter_map do |pattern, pattern_index|
            condition = rule.pattern_conditions.fetch(pattern_index)
            next if condition.bol_only && !@lexer.beginning_of_line?

            regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(::Regexp.escape(pattern.to_s))
            streamed_match(
              regexp, buffer, position, reference: reference_pattern?(regexp),
              limit: :token, rule: rule
            )
              &.then { |match| [match, condition] }
          end
          match, condition = matches.select { |candidate| candidate[0].begin(0).zero? }
            .max_by { |candidate| candidate[0][0].bytesize }
          next unless match

          end_position = position + match[0].bytesize
          next unless @lexer.utf8_boundary?(end_position)
          next if condition.end_anchor && !end_anchor_match?(buffer, end_position)
          trailing = trailing_length(rule, buffer, end_position)
          next if rule.trailing && trailing.nil?

          ensure_token_size!(end_position, position, rule: rule)
          return reusable_match(rule, position, end_position, end_position + (trailing || 0))
        end
        nil
      end

      def streamed_match(pattern, buffer, position, limit:, rule:, reference: false)
        pattern = regexp_pattern(pattern)
        minimum = minimum_match_bytes(pattern)
        loop do
          subject, tail = stream_subject(buffer, position)
          match = match_stream_pattern(pattern, subject, reference: reference)
          ensure_stream_limit!(limit, position, match[0].bytesize, rule) if match
          return match if match && match[0].bytesize < subject.bytesize
          return match if match && %i[eof invalid].include?(tail)
          if !match && subject.bytesize >= minimum && tail != :incomplete
            first_byte = subject.getbyte(0)
            return nil unless first_byte && possible_first_byte?(pattern, first_byte)
            return nil if %i[eof invalid].include?(tail)
          end
          ensure_stream_limit!(limit, position, subject.bytesize, rule) unless match
          @lexer.consume_step!
          return match unless can_refill_match?(buffer)
        end
      end

      def match_stream_pattern(pattern, subject, reference:)
        Regexp::Matcher.match(pattern, subject, encoding: @config.encoding,
                              unicode: @config.options[:unicode] == true, reference: reference)
      end

      def stream_subject(buffer, position)
        return [buffer.byteslice(position...buffer.bytesize).to_s.b, buffer.eof_loaded? ? :eof : :end] unless @lexer.utf8_input?

        cursor = position
        while cursor < buffer.bytesize
          status, length = utf8_status(buffer, cursor)
          break unless status == :complete

          cursor += length
        end
        tail = if cursor < buffer.bytesize
          utf8_status(buffer, cursor).first
        elsif buffer.eof_loaded?
          :eof
        else
          :end
        end
        subject = buffer.byteslice(position, cursor - position).to_s.dup.force_encoding(Encoding::UTF_8)
        [subject, tail]
      end

      def utf8_status(buffer, position)
        return [:eof, 0] if position >= buffer.bytesize

        first = buffer.getbyte(position)
        return [:complete, 1] if first <= 0x7f
        return [:invalid, 1] unless first.between?(0xc2, 0xf4)

        length = if first <= 0xdf
          2
        elsif first <= 0xef
          3
        else
          4
        end
        return [:incomplete, length] unless buffer.ensure_available?(position + length)
        return [:invalid, length] unless buffer.valid_utf8_at?(position)

        [:complete, length]
      end

      def can_refill_match?(buffer)
        buffer.ensure_available?(buffer.bytesize + 1)
      end

      def minimum_match_bytes(pattern)
        return 1 if posix_pattern?(pattern)

        ast = Regexp::Parser.new(pattern.source, options: pattern.options,
                                 encoding: pattern.encoding, unicode: true).parse
        minimum_ast_bytes(ast)
      rescue CompileError, RegexpError
        1
      end

      def regexp_pattern(pattern)
        return pattern if pattern.is_a?(::Regexp)

        ::Regexp.new(::Regexp.escape(pattern.to_s))
      end

      def minimum_ast_bytes(node)
        case node
        when Regexp::AST::Empty, Regexp::AST::Anchor, Regexp::AST::Fail then 0
        when Regexp::AST::ByteRange then 1
        when Regexp::AST::CodepointRange then utf8_length(node.lo)
        when Regexp::AST::CharClass
          ranges = node.ranges.flat_map do |range|
            range.first == Regexp::AST::Property ? property_ranges(range, ignorecase: range[3] == true) : [range]
          end
          ranges = complement_codepoint_ranges(ranges) if node.negated
          ranges.map { |lo, _hi| utf8_length(lo) }.min || 1
        when Regexp::AST::Seq then node.children.sum { |child| minimum_ast_bytes(child) }
        when Regexp::AST::Alt then node.children.map { |child| minimum_ast_bytes(child) }.min || 0
        when Regexp::AST::Repeat then node.minimum * minimum_ast_bytes(node.child)
        else minimum_unknown_bytes(node)
        end
      end

      def minimum_unknown_bytes(node)
        return 0 if node.is_a?(Regexp::AST::Star)

        1
      end

      def possible_first_byte?(pattern, byte)
        return true if posix_pattern?(pattern)

        ast = Regexp::Parser.new(pattern.source, options: pattern.options,
                                 encoding: pattern.encoding, unicode: true).parse
        binary = !@lexer.utf8_input?
        first_byte_ranges(ast, binary: binary).any? { |lo, hi| byte.between?(lo, hi) }
      rescue CompileError, RegexpError
        true
      end

      def first_byte_ranges(node, binary: false)
        case node
        when Regexp::AST::Empty, Regexp::AST::Anchor, Regexp::AST::Fail then []
        when Regexp::AST::ByteRange then [[node.lo, node.hi]]
        when Regexp::AST::CodepointRange
          ranges = [[node.lo, node.hi]]
          return ranges if binary

          ranges.flat_map { |lo, hi| Unicode::Utf8Splitter.split(lo, hi).map(&:first).map(&:first) }
            .map { |value| [value, value] }
        when Regexp::AST::CharClass
          ranges = node.ranges.flat_map do |range|
            range.first == Regexp::AST::Property ? property_ranges(range, ignorecase: range[3] == true) : [range]
          end
          ranges = complement_codepoint_ranges(ranges) if node.negated
          return ranges if binary

          ranges.flat_map { |lo, hi| Unicode::Utf8Splitter.split(lo, hi).map(&:first).map(&:first) }
            .map { |value| [value, value] }
        when Regexp::AST::Seq
          ranges = []
          node.children.each do |child|
            ranges.concat(first_byte_ranges(child, binary: binary))
            break unless nullable?(child)
          end
          ranges
        when Regexp::AST::Alt
          node.children.flat_map { |child| first_byte_ranges(child, binary: binary) }
        when Regexp::AST::Star, Regexp::AST::Repeat
          first_byte_ranges(node.child, binary: binary)
        else
          first_byte_fallback
        end
      end

      def first_byte_fallback
        []
      end

      def nullable?(node)
        case node
        when Regexp::AST::Empty, Regexp::AST::Anchor, Regexp::AST::Star then true
        when Regexp::AST::Repeat then node.minimum.zero? || nullable?(node.child)
        when Regexp::AST::Seq then node.children.all? { |child| nullable?(child) }
        when Regexp::AST::Alt then node.children.any? { |child| nullable?(child) }
        else false
        end
      end

      def utf8_length(codepoint)
        return 1 if codepoint <= 0x7f
        return 2 if codepoint <= 0x7ff
        return 3 if codepoint <= 0xffff

        4
      end

      def complement_codepoint_ranges(ranges)
        result = []
        cursor = 0
        ranges.sort_by(&:first).each do |lo, hi|
          result << [cursor, lo - 1] if cursor < lo
          cursor = [cursor, hi + 1].max
        end
        result << [cursor, 0x10ffff] if cursor <= 0x10ffff
        result
      end

      def property_ranges(range, ignorecase:)
        ranges = Unicode::Property.ranges(range[2])
        ranges = Unicode::CaseFold.merge(ranges.flat_map { |lo, hi| Unicode::CaseFold.ranges(lo, hi) }) if ignorecase
        range[1] ? complement_codepoint_ranges(ranges) : ranges
      end

      def posix_pattern?(pattern)
        pattern.is_a?(::Regexp) && pattern.source.match?(/\[:(?:\^)?[a-z]+:\]/)
      end

      def ensure_stream_limit!(limit, position, size, rule)
        if limit == :lookahead
          @lexer.ensure_lookahead_size!(size, rule: rule)
        else
          ensure_token_size!(position + size, position, rule: rule)
        end
      end

      def rule_active?(rule)
        return true if rule.states.include?(:initial) && @lexer.state == :initial

        state = @config.states.fetch(@lexer.state)
        return true if state.inclusive && rule.states.include?(:initial)

        rule.states.include?(@lexer.state)
      end
    end
  end
end
