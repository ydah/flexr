# frozen_string_literal: true

module Flexr
  module Automaton
    class ReferenceDFA
      def initialize(regexp, unicode: false)
        source, options = if reference_pattern?(regexp, unicode: unicode)
          converted = Unicode::ReferenceRegexp.compiled(
            regexp, encoding: regexp.encoding, options: regexp.options, unicode: unicode
          )
          [converted.source, converted.options]
        else
          [regexp.source, regexp.options]
        end
        @regexp = ::Regexp.new("\\A(?:#{source})\\z", options)
      end

      def accept?(bytes)
        data = bytes.dup.force_encoding(@regexp.encoding)
        @regexp.match?(data)
      rescue ArgumentError, EncodingError
        false
      end

      def stats
        { states: 0, classes: 0, accepting_states: 0, reference: true }
      end

      private

      def reference_pattern?(regexp, unicode: false)
        return true if regexp.source.match?(/\\[pP]\{/) || regexp.source.match?(/\[:(?:\^)?[a-z]+:\]/)

        unicode && regexp.encoding != Encoding::BINARY && regexp.source.match?(/\\[dDwWsS]/)
      end
    end
  end
end
