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
        return scan_fast(machine, position) if fast_path?(machine)

        buffer = @lexer.buffer
        state = machine.dfa.start
        best = reference_match(position, buffer)
        cursor = position
        best = consider_acceptances(machine, state, cursor, position, buffer, best) if @lexer.class.__flexr_config.options[:allow_empty_match]
        acceleration_regions = acceleration_enabled? ? acceleration_regions_for(machine) : nil

        while buffer.ensure_available?(cursor + 1)
          if acceleration_regions && (region = acceleration_regions[state]) &&
              !@disabled_auto_acceleration&.key?(region)
            acceptance = machine.dfa.accepts[state].first
            token_rule = acceptance&.rule_index
            accelerated_end = accelerate(
              region, buffer, cursor, token_rule: token_rule, token_start: position
            )
            if accelerated_end && accelerated_end > cursor
              cursor = accelerated_end
              best = consider_acceptances(machine, state, cursor, position, buffer, best)
              next
            end
          end

          byte = buffer.getbyte(cursor)
          @lexer.consume_step!
          state = transition(machine.dfa, state, byte)
          break unless state

          cursor += 1
          acceptance = machine.dfa.accepts[state].first
          ensure_token_size!(cursor, position, rule: acceptance&.rule_index)
          best = consider_acceptances(machine, state, cursor, position, buffer, best)
        end
        best
      end

      def scan_fast(machine, position)
        buffer = @lexer.buffer
        dfa = machine.dfa
        accepts = dfa.accepts
        rules = @lexer.class.__flexr_rules
        transitions = dfa.transitions
        ec = dfa.ec
        direct = dfa.direct
        direct_nxt = direct&.fetch(:nxt)
        direct_classes = direct&.fetch(:classes)
        source = buffer.stable_source
        guarded_steps = @lexer.scan_steps_guarded?
        scanned_steps = 0
        text_start = @lexer.more_text_start || position
        max_token_size = @lexer.max_token_size
        token_limit_required = @lexer.token_limit_required?
        state = dfa.start
        cursor = position
        best = nil

        if source && !guarded_steps && !token_limit_required
          while cursor < source.bytesize || buffer.ensure_available?(cursor + 1)
            byte = source.getbyte(cursor)
            scanned_steps += 1
            state = if direct_nxt
              class_id = ec[byte]
              value = direct_nxt[(state * direct_classes) + class_id]
              value >= 0 ? value : nil
            else
              transitions[state][ec[byte]]
            end
            break unless state

            cursor += 1
            acceptance = accepts[state].first
            next unless acceptance

            rule = rules.fetch(acceptance.rule_index)
            next if best && cursor == best.total_end_pos && rule.index > best.rule.index

            best ||= (@match ||= Match.new)
            best.rule = rule
            best.start_pos = position
            best.end_pos = cursor
            best.total_end_pos = cursor
          end
          @lexer.record_scan_steps!(scanned_steps)
          return best
        end

        while cursor < buffer.bytesize || buffer.ensure_available?(cursor + 1)
          byte = buffer.getbyte(cursor)
          if guarded_steps
            @lexer.consume_step!
          else
            scanned_steps += 1
          end
          state = if direct_nxt
            class_id = ec[byte]
            value = direct_nxt[(state * direct_classes) + class_id]
            value >= 0 ? value : nil
          else
            transitions[state][ec[byte]]
          end
          break unless state

          cursor += 1
          acceptance = accepts[state].first
          if token_limit_required
            size = cursor - text_start
            @lexer.defer_token_size_check!(size, rule: acceptance&.rule_index) if size > max_token_size
          end
          next unless acceptance

          rule = rules.fetch(acceptance.rule_index)
          next if best && cursor == best.total_end_pos && rule.index > best.rule.index

          best ||= (@match ||= Match.new)
          best.rule = rule
          best.start_pos = position
          best.end_pos = cursor
          best.total_end_pos = cursor
        end
        @lexer.record_scan_steps!(scanned_steps) unless guarded_steps
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

            match = streamed_match(
              pattern, buffer, position, reference: reference_pattern?(pattern),
              limit: :token, rule: rule
            )
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

          ensure_token_size!(end_position, position, rule: rule)
          Match.new(rule: rule, start_pos: position, end_pos: end_position,
                    total_end_pos: end_position + (trailing || 0))
        end
        candidates.max_by { |candidate| [candidate.total_end_pos, -candidate.rule.index] }
      end

      def reference_rules?
        return false unless @lexer.class.__flexr_config.backend == :firstmatch
        return @reference_rules unless @reference_rules.nil?

        @reference_rules = @lexer.class.__flexr_rules.any? do |rule|
          rule.patterns.any? { |pattern| reference_pattern?(pattern) }
        end
      end

      def fast_path?(machine)
        @fast_paths ||= {}
        return @fast_paths[machine.dfa] if @fast_paths.key?(machine.dfa)

        rules = machine.dfa.rule_ids.map { |rule_index| @lexer.class.__flexr_rules.fetch(rule_index) }
        @fast_paths[machine.dfa] = !@lexer.class.__flexr_config.options[:allow_empty_match] &&
          !reference_rules? && rules.none?(&:trailing) &&
          rules.none? { |rule| rule.pattern_conditions.any? { |condition| condition&.bol_only || condition&.end_anchor } }
      end

      def reference_pattern?(pattern)
        return false unless pattern.is_a?(::Regexp)
        return true if pattern.source.match?(/\\[pP]\{/) || pattern.source.match?(/\[:(?:\^)?[a-z]+:\]/)

        @lexer.class.__flexr_config.options[:unicode] == true && @lexer.utf8_input? &&
          pattern.source.match?(/\\[dDwWsS]/)
      end

      def scan_firstmatch(position)
        buffer = @lexer.buffer
        @lexer.class.__flexr_rules.sort_by(&:index).each do |rule|
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

      def trailing_length(rule, buffer, position)
        return 0 unless rule.trailing

        regexp = rule.trailing
        match = streamed_match(
          regexp, buffer, position, reference: reference_pattern?(regexp),
          limit: :lookahead, rule: rule
        )
        return nil unless match&.begin(0)&.zero?

        match[0].bytesize.tap { |size| @lexer.ensure_lookahead_size!(size, rule: rule) }
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
          return match unless can_refill_match?(buffer, position, subject.bytesize, tail)
        end
      end

      def match_stream_pattern(pattern, subject, reference:)
        if reference
          Unicode::ReferenceRegexp.match(
            pattern, subject, encoding: @lexer.class.__flexr_config.encoding,
            options: pattern.options, unicode: @lexer.class.__flexr_config.options[:unicode] == true
          )
        else
          pattern.match(subject, 0)
        end
      rescue ArgumentError, RegexpError
        nil
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

      def regexp_pattern(pattern)
        return pattern if pattern.is_a?(::Regexp)

        ::Regexp.new(::Regexp.escape(pattern.to_s))
      end

      def minimum_ast_bytes(node, ignorecase: false)
        case node
        when Regexp::AST::Empty, Regexp::AST::Anchor, Regexp::AST::Fail then 0
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
        when Regexp::AST::Repeat then node.minimum * minimum_ast_bytes(node.child, ignorecase: ignorecase)
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
        when Regexp::AST::Empty, Regexp::AST::Anchor, Regexp::AST::Fail then []
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
        when Regexp::AST::Star, Regexp::AST::Repeat
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

          ensure_token_size!(cursor, position, rule: candidate)
          best = @match ||= Match.new
          best.rule = candidate
          best.start_pos = position
          best.end_pos = cursor
          best.total_end_pos = total_end
        end
        best
      end

      def acceleration_enabled?
        mode = @lexer.class.__flexr_config.options.fetch(:accel, :auto)
        mode != :none && !(mode == :auto && @auto_acceleration_off)
      end

      def reusable_match(rule, start_pos, end_pos, total_end_pos)
        @match ||= Match.new
        @match.rule = rule
        @match.start_pos = start_pos
        @match.end_pos = end_pos
        @match.total_end_pos = total_end_pos
        @match
      end

      def accelerate(region, buffer, position, token_rule:, token_start:)
        mode = @lexer.class.__flexr_config.options.fetch(:accel, :auto)
        cursor = position
        matched = false
        loop do
          if cursor >= buffer.bytesize
            return matched ? cursor : nil if buffer.eof_loaded?
            return matched ? cursor : nil unless buffer.ensure_available?(cursor + 1)
          end

          segment = buffer.source
          segment_position = cursor - buffer.base_offset
          length = acceleration_length(region, segment, segment_position, mode)
          record_auto_acceleration_miss(region) if mode == :auto && length.to_i < 8
          return matched ? cursor : nil unless length&.positive?

          matched = true
          cursor += length
          @lexer.consume_step!(length)
          ensure_token_size!(cursor, token_start, rule: token_rule)
          return cursor if cursor < buffer.bytesize || buffer.eof_loaded?
        end
      end

      def acceleration_length(region, segment, position, mode)
        if segment.encoding == Encoding::UTF_8 && region.utf8_regexp
          regexp = region.utf8_regexp
        else
          segment = segment.b unless segment.encoding == Encoding::BINARY
          regexp = region.regexp
        end
        if %i[strscan auto].include?(mode) && defined?(::StringScanner)
          @acceleration_scanner ||= ::StringScanner.new("".b)
          @acceleration_scanner.string = segment
          @acceleration_scanner.pos = position
          @acceleration_scanner.skip(regexp)
        else
          match = regexp.match(segment, position)
          match&.begin(0) == position ? match.end(0) - position : nil
        end
      rescue ArgumentError
        nil
      end

      def record_auto_acceleration_miss(region)
        @auto_acceleration_misses ||= Hash.new(0)
        @auto_acceleration_misses[region] += 1
        @auto_acceleration_miss_total = @auto_acceleration_miss_total.to_i + 1
        @auto_acceleration_off = true if @auto_acceleration_miss_total >= 9
        return if @auto_acceleration_misses[region] < 3

        @disabled_auto_acceleration ||= {}
        @disabled_auto_acceleration[region] = true
      end

      def transition(dfa, state, byte)
        return dfa.transition_direct(state, byte) if @lexer.class.__flexr_config.backend == :direct

        dfa.transition(state, byte)
      end

      def acceleration_regions_for(machine)
        @acceleration_regions ||= {}
        return @acceleration_regions[machine.dfa] if @acceleration_regions.key?(machine.dfa)

        @acceleration_regions[machine.dfa] = Automaton::Accel.extract(machine.dfa).filter_map do |region|
          next if region.bytes.any? { |byte| byte >= 128 }

          accepting = machine.dfa.accepts[region.state]
          next if accepting.any? do |acceptance|
            rule = @lexer.class.__flexr_rules.fetch(acceptance.rule_index)
            acceptance.bol_only || acceptance.end_anchor || rule.trailing
          end

          [region.state, region]
        end.to_h
      end

      def end_anchor_match?(buffer, position)
        buffer.eof?(position) || buffer.getbyte(position) == 0x0a
      end

      def ensure_token_size!(end_position, position, rule: nil)
        text_start = @lexer.more_text_start || position
        @lexer.defer_token_size_check!(end_position - text_start, rule: rule)
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

        state = @lexer.class.__flexr_config.states.fetch(@lexer.state)
        return true if state.inclusive && rule.states.include?(:initial)

        rule.states.include?(@lexer.state)
      end

    end
  end
end
