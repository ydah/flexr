# frozen_string_literal: true

begin
  require "strscan"
rescue LoadError
  # StringScanner is an optional accelerator; the regexp path remains valid.
end

module Flexr
  module Runtime
    Match = Struct.new(:rule, :start_pos, :end_pos, :total_end_pos, :capture, keyword_init: true)

    class Interpreter
      include Firstmatch if defined?(Firstmatch)

      def initialize(lexer)
        @lexer = lexer
        klass = lexer.class
        @compiled = klass.__flexr_runtime_compiled
        @lazy = !@compiled.equal?(klass.__flexr_compiled)
        @rules = klass.__flexr_rules
        @config = klass.__flexr_config
        @recover_backup = lexer.__flexr_recovers_unmatched?
        @scan_source = lexer.buffer.scan_source
      end

      def scan(expected = nil)
        machine = @compiled.machines.fetch(@lexer.state)
        position = @lexer.byte_pos
        return nil unless @lexer.valid_utf8_at?(position)
        return scan_firstmatch(position, expected) if @config.backend == :firstmatch
        if !expected && fast_path?(machine)
          if machine.whole_tokens
            match = @lexer.__flexr_whole_token_match(machine.whole_tokens, position)
            return match if match
          end

          return scan_fast(machine, position)
        end

        scan_with_conditions(machine, position, expected)
      end

      def scan_fast(machine, position)
        dfa = machine.dfa
        accepts = dfa.accepts
        rules = @rules
        transitions = dfa.transitions
        ec = dfa.ec
        direct = dfa.direct
        direct_nxt = direct&.fetch(:nxt)
        direct_classes = direct&.fetch(:classes)
        lazy = @lazy
        memo_states = (@recover_backup && machine.backup_recovery_states) || machine.backup_memo_states
        source = @scan_source
        return scan_with_conditions(machine, position, nil, simple: true) unless
          source && !@lexer.scan_steps_guarded? && !@lexer.token_limit_required?

        state = dfa.start
        cursor = position
        best = nil

        while (byte = source.getbyte(cursor))
          target = if direct_nxt
            class_id = ec[byte]
            value = direct_nxt[(state * direct_classes) + class_id]
            value >= 0 ? value : nil
          else
            transitions[state][ec[byte]]
          end
          unless target
            target = dfa.transition(state, byte) if lazy && target.nil?
            break unless target
          end
          state = target

          cursor += 1
          acceptance = accepts[state].first
          unless acceptance
            next unless memo_states&.[](state)

            result = @lexer.__flexr_backup_suffix(dfa, memo_states, state, cursor, position)
            break if result == false
            next unless result

            state, cursor = result
            acceptance = accepts[state].first
          end

          rule = rules.fetch(acceptance.rule_index)
          best ||= (@fast_match ||= Match.new)
          best.rule = rule
          best.start_pos = position
          best.end_pos = cursor
          best.total_end_pos = cursor
        end
        best
      end

      private

      def scan_with_conditions(machine, position, expected, simple: false)
        buffer = @lexer.buffer
        memo_states = (@recover_backup && machine.backup_recovery_states) || machine.backup_memo_states
        memo_states = nil if memo_states && @lexer.scan_steps_guarded?
        state = machine.dfa.start
        best = nil
        cursor = position
        best = consider_acceptances(machine, state, cursor, position, buffer, best, expected) if @config.options[:allow_empty_match]
        acceleration_regions = acceleration_regions_for(machine) if
          !simple && !expected && !@lazy && acceleration_enabled?

        while buffer.ensure_available?(cursor + 1)
          if acceleration_regions && !memo_states&.[](state) && (region = acceleration_regions[state]) &&
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
          if !acceptance && memo_states&.[](state)
            result = @lexer.__flexr_backup_suffix(machine.dfa, memo_states, state, cursor, position)
            break if result == false

            state, cursor = result if result
          end
          best = consider_acceptances(machine, state, cursor, position, buffer, best, expected, check_boundary: !simple)
        end
        best
      end

      def fast_path?(machine)
        return @fast_path if @fast_path_machine.equal?(machine)

        paths = (@fast_paths ||= {}.compare_by_identity)
        @fast_path = paths.fetch(machine) do
          rules = machine.dfa.rule_ids.map { |rule_index| @rules.fetch(rule_index) }
          paths[machine] = !@config.options[:allow_empty_match] &&
            rules.none?(&:trailing) && rules.none?(&:capture_patterns) &&
            rules.none? { |rule| rule.pattern_conditions.any? { |condition| condition&.bol_only || condition&.end_anchor } }
        end
        @fast_path_machine = machine
        @fast_path
      end

      def trailing_length(rule, buffer, position)
        return 0 unless rule.trailing

        dfa = rule.trailing_dfa || trailing_dfa(rule.trailing)
        state = dfa.start
        cursor = position
        longest = 0 if trailing_accept?(dfa, state, buffer, cursor, position)
        while buffer.ensure_available?(cursor + 1)
          state = dfa.transition(state, buffer.getbyte(cursor))
          break unless state

          cursor += 1
          @lexer.consume_step!
          size = cursor - position
          @lexer.ensure_lookahead_size!(size, rule: rule)
          longest = size if trailing_accept?(dfa, state, buffer, cursor, position)
        end
        longest
      end

      def trailing_accept?(dfa, state, buffer, ending, starting)
        acceptance = dfa.accepts[state].first
        return false unless acceptance
        return false if acceptance.bol_only && !@lexer.__flexr_beginning_of_line_at?(starting, @lexer.byte_pos)
        return false unless @lexer.utf8_boundary?(ending)

        !acceptance.end_anchor || end_anchor_match?(buffer, ending)
      end

      def trailing_dfa(pattern)
        @trailing_dfas ||= {}
        @trailing_dfas[pattern] ||= Flexr.compile_pattern(
          pattern, encoding: @config.encoding, options: { unicode: @config.options[:unicode] == true }
        )
      end

      def consider_acceptances(machine, state, cursor, position, buffer, best, expected = nil, check_boundary: true)
        machine.dfa.accepts[state].each do |acceptance|
          candidate = @rules.fetch(acceptance.rule_index)
          next if acceptance.bol_only && !@lexer.beginning_of_line?
          next if check_boundary && !@lexer.utf8_boundary?(cursor)
          next unless !acceptance.end_anchor || end_anchor_match?(buffer, cursor)
          next if expected && !expected_rule?(candidate, expected, buffer, position, cursor)

          trailing_size = trailing_length(candidate, buffer, cursor)
          next if candidate.trailing && trailing_size.nil?

          total_end = cursor + (trailing_size || 0)
          next if best && total_end < best.total_end_pos
          if best && total_end == best.total_end_pos
            next if candidate.loses_priority_tie?(best.rule)
            next if candidate.capture_patterns && candidate.equal?(best.rule) && cursor == best.end_pos
          end

          ensure_token_size!(cursor, position, rule: candidate)
          best = @match ||= Match.new
          best.rule = candidate
          best.start_pos = position
          best.end_pos = cursor
          best.total_end_pos = total_end
          best.capture = candidate.capture_patterns&.[](acceptance.pattern_index)
        end
        best
      end

      def expected_rule?(rule, expected, buffer, start_pos, end_pos = nil)
        return true if rule.skip? || rule.channel
        return true if @config.options[:indentation] && @lexer.__flexr_layout_candidate?(expected, start_pos, end_pos)
        return rule.emits.any? { |type| expected.key?(type) } if rule.emits
        return true unless rule.emit?

        type = rule.action[1]
        if (table = @config.options[:keyword_tables]&.[](type))
          return expected.key?(type) || table.any? { |_, entry| expected.key?(entry.first) } unless end_pos

          lexeme = buffer.byteslice(start_pos, end_pos - start_pos).force_encoding(Encoding::UTF_8)
          type = table[lexeme]&.first || type
        end
        expected.key?(type)
      end

      def acceleration_enabled?
        mode = @config.options.fetch(:accel, :auto)
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
        mode = @config.options.fetch(:accel, :auto)
        cursor = position
        matched = false
        loop do
          if cursor >= buffer.bytesize
            return matched ? cursor : nil if buffer.eof_loaded?
            return matched ? cursor : nil unless buffer.ensure_available?(cursor + 1)
          end

          segment = buffer.__send__(:acceleration_source)
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
          match = regexp.match(segment.byteslice(position..).to_s, 0)
          match&.begin(0)&.zero? ? match[0].bytesize : nil
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
        return dfa.transition_direct(state, byte) if @config.backend == :direct

        dfa.transition(state, byte)
      end

      def acceleration_regions_for(machine)
        @acceleration_regions ||= {}
        return @acceleration_regions[machine.dfa] if @acceleration_regions.key?(machine.dfa)

        @acceleration_regions[machine.dfa] = Automaton::Accel.extract(machine.dfa).filter_map do |region|
          next if region.bytes.any? { |byte| byte >= 128 }

          accepting = machine.dfa.accepts[region.state]
          next if accepting.any? do |acceptance|
            rule = @rules.fetch(acceptance.rule_index)
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
    end
  end
end
