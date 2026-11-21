# frozen_string_literal: true

require "minitest/assertions"
require_relative "testing"

module Flexr
  module Minitest
    module Assertions
      def assert_tokenize(lexer, input, expected, **options)
        assert_equal expected, lexer.new(input, **options).tokens
      end

      def assert_token_snapshot(lexer, input, path, update: false, **options)
        actual = Testing::Snapshot.render(lexer.new(input, **options).tokens)
        begin
          expected = Testing::Snapshot.expected(path, actual, update: update)
        rescue Errno::ENOENT
          flunk "missing token snapshot #{path}; create it with update: true"
        end
        assert_equal expected, actual, "token snapshot differs: #{path}"
      end
    end
  end
end
