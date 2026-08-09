# frozen_string_literal: true

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

        while buffer.ensure_available?(cursor + 1)
          byte = buffer.getbyte(cursor)
          state = machine.dfa.transition(state, byte)
          break unless state

          cursor += 1
          machine.dfa.accepts[state].each do |rule_index|
            candidate = @lexer.class.__flexr_rules.fetch(rule_index)
            next if candidate.bol_only && !@lexer.beginning_of_line?
            next unless @lexer.utf8_boundary?(cursor)
            next unless candidate.end_anchor.nil? || end_anchor_match?(buffer, cursor)

            trailing_length = trailing_length(candidate, buffer, cursor)
            next if candidate.trailing && trailing_length.nil?

            total_end = cursor + (trailing_length || 0)
            next if best && total_end < best.total_end_pos
            next if best && total_end == best.total_end_pos && rule_index > best.rule.index

            ensure_token_size!(cursor, position)
            best = Match.new(rule: candidate, start_pos: position, end_pos: cursor,
                             total_end_pos: total_end)
          end
        end
        best
      end

      private

      def reference_match(position, buffer)
        return unless reference_rules?

        data = buffer.read_to_end.dup.force_encoding(
          @lexer.utf8_input? ? Encoding::UTF_8 : Encoding::BINARY
        )
        candidates = @lexer.class.__flexr_rules.filter_map do |rule|
          next unless rule.patterns.any? { |pattern| pattern.is_a?(::Regexp) && pattern.source.include?("\\p{") }
          next if rule.bol_only && !@lexer.beginning_of_line?

          matches = rule.patterns.filter_map do |pattern|
            Unicode::ReferenceRegexp.match(
              pattern, data.byteslice(position..), encoding: @lexer.class.__flexr_config.encoding,
              options: pattern.options, unicode: @lexer.class.__flexr_config.options[:unicode] == true
            )
          end
          match = matches.max_by { |item| item[0].bytesize }
          next unless match&.begin(0)&.zero?

          end_position = position + match[0].bytesize
          next unless @lexer.utf8_boundary?(end_position)
          next if rule.end_anchor && !end_anchor_match?(buffer, end_position)

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
          rule.patterns.any? { |pattern| pattern.is_a?(::Regexp) && pattern.source.include?("\\p{") }
        end
      end

      def scan_firstmatch(position)
        buffer = @lexer.buffer
        subject = buffer.read_to_end.dup.force_encoding(
          @lexer.utf8_input? ? Encoding::UTF_8 : Encoding::BINARY
        )
        @lexer.class.__flexr_rules.sort_by(&:index).each do |rule|
          next if rule.bol_only && !@lexer.beginning_of_line?

          matches = rule.patterns.filter_map do |pattern|
            regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(::Regexp.escape(pattern.to_s))
            regexp.match(subject.byteslice(position..), 0)
          rescue ArgumentError, RegexpError
            nil
          end
          match = matches.select { |candidate| candidate.begin(0).zero? }.max_by { |candidate| candidate[0].bytesize }
          next unless match

          end_position = position + match[0].bytesize
          next unless @lexer.utf8_boundary?(end_position)
          next if rule.end_anchor && !end_anchor_match?(buffer, end_position)
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
        segment = buffer.read_to_end.byteslice(position..)
        match = regexp.match(segment, 0)
        return nil unless match&.begin(0)&.zero?

        match[0].bytesize
      rescue ArgumentError
        nil
      end

      def end_anchor_match?(buffer, position)
        buffer.eof?(position) || buffer.getbyte(position) == 0x0a
      end

      def ensure_token_size!(end_position, position)
        text_start = @lexer.more_text_start || position
        @lexer.defer_token_size_check!(end_position - text_start)
      end

    end
  end
end
