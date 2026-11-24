# frozen_string_literal: true

module Flexr
  module Runtime
    module Captures
      def captures
        return EMPTY_CAPTURES unless @capture_match

        @captures ||= capture_data.named_captures(symbolize_names: true).transform_values(&:freeze).freeze
      end

      private

      def execute_with_captures(match)
        @capture_match = match
        @capture_following_lf = match.capture.is_a?(Array) && @buffer.getbyte(match.end_pos) == 0x0a
        execute(match.rule)
        finish_delegation if @__flexr_delegation_end
      ensure
        @capture_match = @captures = @capture_data = @capture_following_lf = nil
        @__flexr_delegation_tokens = @__flexr_delegation_end = nil
      end

      def capture_data
        @capture_data ||= replay_capture_data
      end

      def replay_capture_data
        match = @capture_match
        return match.capture if match.capture.respond_to?(:byteoffset)

        regexp = match.capture
        if regexp.respond_to?(:instructions)
          data = regexp.match(self, match.rule, match.start_pos, ending: match.end_pos)
          return data || capture_replay_error(match)
        end
        regexp = regexp.fetch(@capture_following_lf ? 1 : 0) if regexp.is_a?(Array)
        subject = @buffer.byteslice(match.start_pos, match.end_pos - match.start_pos)
        encoding = if regexp.options.anybits?(::Regexp::NOENCODING)
          Encoding::BINARY
        else
          self.class.__flexr_config.encoding
        end
        subject.force_encoding(encoding)
        data = regexp.match(@capture_following_lf ? "#{subject}\n" : subject)
        return data if data

        capture_replay_error(match)
      end

      def capture_replay_error(match)
        message = "Ruby could not replay named captures for #{Diagnostics.rule_label(match.rule)}"
        subject = @buffer.byteslice(match.start_pos, match.end_pos - match.start_pos)
        raise LexError.new(message, filename: @filename, byte_pos: match.start_pos, line: @line, text: subject)
      end
    end
  end
end
