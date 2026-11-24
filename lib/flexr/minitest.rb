# frozen_string_literal: true

require "minitest/assertions"
require_relative "testing"

module Flexr
  module Minitest
    module Assertions
      def assert_tokenize(lexer, input, expected, **)
        assert_equal expected, lexer.new(input, **).tokens
      end

      def assert_token_snapshot(lexer, input, path, update: false, **)
        actual = Testing::Snapshot.render(lexer.new(input, **).tokens)
        begin
          expected = Testing::Snapshot.expected(path, actual, update: update)
        rescue Errno::ENOENT
          flunk "missing token snapshot #{path}; create it with update: true"
        end
        assert_equal expected, actual, "token snapshot differs: #{path}"
      end

      def assert_disjoint_tokens(lexer, first, second, state: :initial)
        assert_language Testing::Languages.disjoint_tokens(lexer, first, second, state: state)
      end

      def assert_includes_language(superset, subset, encoding: Encoding::UTF_8, unicode: false)
        assert_language Testing::Languages.include_language(superset, subset, encoding: encoding, unicode: unicode)
      end

      def assert_tokenize_like(actual, expected, state: :initial)
        assert_language Testing::Languages.tokenize_like(actual, expected, state: state)
      end

      private

      def assert_language(result)
        assert result.status == :equal, result.failure_message
      end
    end
  end
end
