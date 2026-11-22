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
        execute(match.rule)
      ensure
        @capture_match = @captures = nil
      end

      def capture_data
        match = @capture_match
        return match.capture if match.capture.is_a?(MatchData)

        regexp = match.capture
        subject = @buffer.byteslice(match.start_pos, match.end_pos - match.start_pos)
        encoding = if regexp.options.anybits?(::Regexp::NOENCODING)
          Encoding::BINARY
        else
          self.class.__flexr_config.encoding
        end
        data = regexp.match(subject.force_encoding(encoding))
        return data if data

        message = "Ruby could not replay named captures for #{Diagnostics.rule_label(match.rule)}"
        raise LexError.new(message, filename: @filename, byte_pos: match.start_pos, line: @line, text: subject)
      end
    end
  end
end
