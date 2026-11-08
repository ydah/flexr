# frozen_string_literal: true

module Flexr
  module Regexp
    module Matcher
      module_function

      def reference?(pattern, encoding:, unicode: false)
        return false unless pattern.is_a?(::Regexp)
        return true if pattern.source.match?(/\\[pP]\{/) || pattern.source.match?(/\[:(?:\^)?[a-z]+:\]/)

        unicode && encoding == Encoding::UTF_8 && pattern.source.match?(/\\[dDwWsS]/)
      end

      def match(pattern, subject, encoding:, unicode:, reference:)
        if reference
          Unicode::ReferenceRegexp.match(pattern, subject, encoding: encoding, options: pattern.options, unicode: unicode)
        else
          pattern.match(subject, 0)
        end
      rescue ArgumentError, RegexpError
        nil
      end
    end
  end
end
