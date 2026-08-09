# frozen_string_literal: true

begin
  require "strscan"
rescue LoadError
  # StringScanner is an optional accelerator; the regexp path remains valid.
end

module Flexr
  module Runtime
    Match = Struct.new(:rule, :start_pos, :end_pos, :total_end_pos, keyword_init: true)

    class Interpreter
      def initialize(lexer)
        @lexer = lexer
      end

      def scan
        machine = @lexer.class.__flexr_compiled.machines.fetch(@lexer.state)
        position = @lexer.byte_pos
        return nil unless @lexer.valid_utf8_at?(position)
        return scan_firstmatch(position) if @lexer.class.__flexr_config.backend == :firstmatch

        buffer = @lexer.buffer
        state = machine.dfa.start
        best = reference_match(position, buffer)
        cursor = position
        best = consider_acceptances(machine, state, cursor, position, buffer, best) if @lexer.class.__flexr_config.options[:allow_empty_match]
        accelerated = acceleration_enabled?

        while buffer.ensure_available?(cursor + 1)
          if accelerated
            region = acceleration_region(machine, state)
            if region
              accelerated_end = accelerate(region, buffer, cursor)
              if accelerated_end && accelerated_end > cursor
                cursor = accelerated_end
                best = consider_acceptances(machine, state, cursor, position, buffer, best)
                next
              end
            end
          end

          byte = buffer.getbyte(cursor)
          state = transition(machine.dfa, state, byte)
          break unless state

          cursor += 1
          best = consider_acceptances(machine, state, cursor, position, buffer, best)
        end
        best
      end

      private

      def reference_match(position, buffer)
        return unless reference_rules?

        candidates = @lexer.class.__flexr_rules.filter_map do |rule|
          next unless rule_active?(rule)
          next unless rule.patterns.any? { |pattern| reference_pattern?(pattern) }

          matches = rule.patterns.each_with_index.filter_map do |pattern, pattern_index|
            condition = rule.pattern_conditions.fetch(pattern_index)
            next if condition.bol_only && !@lexer.beginning_of_line?

            match = streamed_match(pattern, buffer, position, reference: true)
            next unless match&.begin(0)&.zero?

            end_position = position + match[0].bytesize
            next unless @lexer.utf8_boundary?(end_position)
            next if condition.end_anchor && !end_anchor_match?(buffer, end_position)

            [match, condition]
          end
          match, _condition = matches.max_by { |item| item[0][0].bytesize }
          next unless match&.begin(0)&.zero?

          end_position = position + match[0].bytesize
          next unless @lexer.utf8_boundary?(end_position)

          trailing = trailing_length(rule, buffer, end_position)
          next if rule.trailing && trailing.nil?

          ensure_token_size!(end_position, position)
          Match.new(rule: rule, start_pos: position, end_pos: end_position,
                    total_end_pos: end_position + (trailing || 0))
        end
        candidates.max_by { |candidate| [candidate.total_end_pos, -candidate.rule.index] }
      end

      def reference_rules?
        @lexer.class.__flexr_rules.any? do |rule|
          rule.patterns.any? { |pattern| reference_pattern?(pattern) }
        end
      end

      def reference_pattern?(pattern)
        pattern.is_a?(::Regexp) &&
          (pattern.source.include?("\\p{") || pattern.source.match?(/\[:(?:\^)?[a-z]+:\]/))
      end

      def scan_firstmatch(position)
        buffer = @lexer.buffer
        @lexer.class.__flexr_rules.sort_by(&:index).each do |rule|
          next unless rule_active?(rule)

          matches = rule.patterns.each_with_index.filter_map do |pattern, pattern_index|
            condition = rule.pattern_conditions.fetch(pattern_index)
            next if condition.bol_only && !@lexer.beginning_of_line?

            regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(::Regexp.escape(pattern.to_s))
            streamed_match(regexp, buffer, position)&.then { |match| [match, condition] }
          rescue ArgumentError, RegexpError
            nil
          end
          match, condition = matches.select { |candidate| candidate[0].begin(0).zero? }
            .max_by { |candidate| candidate[0][0].bytesize }
          next unless match

          end_position = position + match[0].bytesize
          next unless @lexer.utf8_boundary?(end_position)
          next if condition.end_anchor && !end_anchor_match?(buffer, end_position)
          trailing = trailing_length(rule, buffer, end_position)
          next if rule.trailing && trailing.nil?

          ensure_token_size!(end_position, position)
          return Match.new(rule: rule, start_pos: position, end_pos: end_position,
                           total_end_pos: end_position + (trailing || 0))
        end
        nil
      end

      def trailing_length(rule, buffer, position)
        return 0 unless rule.trailing

        regexp = rule.trailing
        match = streamed_match(regexp, buffer, position)
        return nil unless match&.begin(0)&.zero?

        match[0].bytesize
      rescue ArgumentError
        nil
      end

      def streamed_match(pattern, buffer, position, reference: false)
        minimum = minimum_match_bytes(pattern)
        loop do
          subject, tail = stream_subject(buffer, position)
          match = if reference && !posix_pattern?(pattern)
            Unicode::ReferenceRegexp.match(
              pattern, subject, encoding: @lexer.class.__flexr_config.encoding,
              options: pattern.options, unicode: @lexer.class.__flexr_config.options[:unicode] == true
            )
          else
            pattern.match(subject, 0)
          end
          return match if match && match[0].bytesize < subject.bytesize
          return match if match && %i[eof invalid].include?(tail)
          if !match && subject.bytesize >= minimum && tail != :incomplete
            first_byte = subject.getbyte(0)
            return nil unless first_byte && possible_first_byte?(pattern, first_byte)
            return nil if %i[eof invalid].include?(tail)
          end
          return match unless can_refill_match?(buffer, position, subject.bytesize, tail)
        rescue ArgumentError, RegexpError
          return nil
        end
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

        first = buffer.source.getbyte(position)
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

      def can_refill_match?(buffer, position, subject_size, tail)
        target = if tail == :incomplete
          position + subject_size + 1
        else
          buffer.bytesize + 1
        end
        buffer.ensure_available?(target)
      end

      def minimum_match_bytes(pattern)
        return 1 if posix_pattern?(pattern)

        ast = Regexp::Parser.new(pattern.source, options: pattern.options,
                                 encoding: pattern.encoding, unicode: true).parse
        minimum_ast_bytes(ast, ignorecase: pattern.options.anybits?(::Regexp::IGNORECASE))
      rescue CompileError, RegexpError
        1
      end

      def minimum_ast_bytes(node, ignorecase: false)
        case node
        when Regexp::AST::Empty, Regexp::AST::Anchor then 0
        when Regexp::AST::ByteRange then 1
        when Regexp::AST::CodepointRange then utf8_length(node.lo)
        when Regexp::AST::CharClass
          ranges = node.ranges.flat_map do |range|
            range.first == Regexp::AST::Property ? property_ranges(range, ignorecase: ignorecase) : [range]
          end
          ranges = complement_codepoint_ranges(ranges) if node.negated
          ranges.map { |lo, _hi| utf8_length(lo) }.min || 1
        when Regexp::AST::Seq then node.children.sum { |child| minimum_ast_bytes(child, ignorecase: ignorecase) }
        when Regexp::AST::Alt then node.children.map { |child| minimum_ast_bytes(child, ignorecase: ignorecase) }.min || 0
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
        first_byte_ranges(ast, pattern.options, binary: binary).any? { |lo, hi| byte.between?(lo, hi) }
      rescue CompileError, RegexpError
        true
      end

      def first_byte_ranges(node, options, binary: false)
        case node
        when Regexp::AST::Empty, Regexp::AST::Anchor then []
        when Regexp::AST::ByteRange then [[node.lo, node.hi]]
        when Regexp::AST::CodepointRange
          ranges = options.anybits?(::Regexp::IGNORECASE) ? Unicode::CaseFold.ranges(node.lo, node.hi) : [[node.lo, node.hi]]
          return ranges if binary

          ranges.flat_map { |lo, hi| Unicode::Utf8Splitter.split(lo, hi).map(&:first).map(&:first) }
            .map { |value| [value, value] }
        when Regexp::AST::CharClass
          ranges = node.ranges.flat_map do |range|
            range.first == Regexp::AST::Property ? property_ranges(range, ignorecase: options.anybits?(::Regexp::IGNORECASE)) : [range]
          end
          ranges = complement_codepoint_ranges(ranges) if node.negated
          return ranges if binary

          ranges.flat_map { |lo, hi| Unicode::Utf8Splitter.split(lo, hi).map(&:first).map(&:first) }
            .map { |value| [value, value] }
        when Regexp::AST::Seq
          ranges = []
          node.children.each do |child|
            ranges.concat(first_byte_ranges(child, options, binary: binary))
            break unless nullable?(child)
          end
          ranges
        when Regexp::AST::Alt
          node.children.flat_map { |child| first_byte_ranges(child, options, binary: binary) }
        when Regexp::AST::Star
          first_byte_ranges(node.child, options, binary: binary)
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

      def consider_acceptances(machine, state, cursor, position, buffer, best)
        machine.dfa.accepts[state].each do |acceptance|
          candidate = @lexer.class.__flexr_rules.fetch(acceptance.rule_index)
          next if acceptance.bol_only && !@lexer.beginning_of_line?
          next unless @lexer.utf8_boundary?(cursor)
          next unless !acceptance.end_anchor || end_anchor_match?(buffer, cursor)

          trailing_size = trailing_length(candidate, buffer, cursor)
          next if candidate.trailing && trailing_size.nil?

          total_end = cursor + (trailing_size || 0)
          next if best && total_end < best.total_end_pos
          next if best && total_end == best.total_end_pos && acceptance.rule_index > best.rule.index

          ensure_token_size!(cursor, position)
          best = Match.new(rule: candidate, start_pos: position, end_pos: cursor,
                           total_end_pos: total_end)
        end
        best
      end

      def acceleration_enabled?
        @lexer.class.__flexr_config.options.fetch(:accel, :auto) != :none && !@lexer.utf8_input?
      end

      def accelerate(region, buffer, position)
        mode = @lexer.class.__flexr_config.options.fetch(:accel, :auto)
        binary = buffer.source.b
        match_end = if mode == :strscan && defined?(StringScanner)
          scanner = StringScanner.new(binary)
          scanner.pos = position
          length = scanner.skip(region.regexp)
          length && scanner.pos
        else
          region.regexp.match(binary, position)&.then { |match| match.begin(0) == position ? match.end(0) : nil }
        end
        return match_end if match_end && match_end < buffer.bytesize
        return match_end if match_end && buffer.eof_loaded?
        return unless buffer.ensure_available?(buffer.bytesize + 1)

        accelerate(region, buffer, position)
      rescue ArgumentError
        nil
      end

      def transition(dfa, state, byte)
        if @lexer.class.__flexr_config.backend == :direct &&
            @lexer.class.respond_to?(:__flexr_generated_direct_transition)
          return @lexer.class.__flexr_generated_direct_transition(@lexer.state, state, byte)
        end
        return dfa.transition_direct(state, byte) if @lexer.class.__flexr_config.backend == :direct

        dfa.transition(state, byte)
      end

      def acceleration_region(machine, state)
        @acceleration_regions ||= Automaton::Accel.extract(machine.dfa).to_h { |region| [region.state, region] }
        region = @acceleration_regions[state]
        return unless region

        accepting = machine.dfa.accepts[state]
        return if accepting.any? do |acceptance|
          rule = @lexer.class.__flexr_rules.fetch(acceptance.rule_index)
          acceptance.bol_only || acceptance.end_anchor || rule.trailing
        end

        region
      end

      def end_anchor_match?(buffer, position)
        buffer.eof?(position) || buffer.getbyte(position) == 0x0a
      end

      def ensure_token_size!(end_position, position)
        text_start = @lexer.more_text_start || position
        @lexer.defer_token_size_check!(end_position - text_start)
      end

      def rule_active?(rule)
        return true if rule.states.include?(:initial) && @lexer.state == :initial

        state = @lexer.class.__flexr_config.states.fetch(@lexer.state)
        return true if state.inclusive && rule.states.include?(:initial)

        rule.states.include?(@lexer.state)
      end

    end
  end
end
