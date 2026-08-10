# frozen_string_literal: true

module Flexr
  module Runtime
    class TokenTooLargeError < LexError
      CODE = "FLEXR-E012"

      attr_reader :code

      def initialize(message = "token exceeds max_token_size", filename: nil, byte_pos: nil, line: nil, text: nil)
        @code = CODE
        diagnostic = Diagnostics.error(
          CODE,
          message,
          help: "increase max_token_size or split the input token"
        )
        super(message, filename: filename, byte_pos: byte_pos, line: line, text: text, diagnostic: diagnostic)
      end
    end
    class StateStackOverflowError < LexError; end
  end
end
