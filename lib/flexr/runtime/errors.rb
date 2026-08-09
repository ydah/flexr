# frozen_string_literal: true

module Flexr
  module Runtime
    class TokenTooLargeError < LexError; end
    class StateStackOverflowError < LexError; end
  end
end
