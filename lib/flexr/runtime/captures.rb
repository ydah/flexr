# frozen_string_literal: true

module Flexr
  module Runtime
    module Captures
      def input
        @buffer.capture_source_exposed = true if !@string_input && defined?(TaggedCaptures)
        super
      end

      def captures
        return EMPTY_CAPTURES unless @capture_match

        @captures ||= capture_data.named_captures(symbolize_names: true).transform_values(&:freeze).freeze
      end

      private

      def __flexr_tagged_captures(dfa)
        # shortcut: replay if a cancellation callback may edit scanned bytes, use tags when edits can be detected.
        return if @cancellation || !defined?(TaggedCaptures) || @buffer.capture_source_exposed

        @__flexr_tagged_trackers ||= {}.compare_by_identity
        tracker = @__flexr_tagged_trackers.fetch(dfa) do
          @__flexr_tagged_trackers[dfa] = TaggedCaptures.for_dfa(dfa, self.class.__flexr_rules)
        end
        tracker&.reset
      end

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
        regexp = match.capture
        if defined?(TaggedCaptures::CapturedMatch) && regexp.is_a?(TaggedCaptures::CapturedMatch)
          return regexp if regexp.valid_in?(@buffer)

          regexp = regexp.fallback
        end
        return regexp if regexp.respond_to?(:byteoffset)

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
