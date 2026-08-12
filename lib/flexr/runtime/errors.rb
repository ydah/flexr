# frozen_string_literal: true

module Flexr
  module Runtime
    class TokenTooLargeError < LexError
      CODE = "FLEXR-E012"

      attr_reader :code, :rule

      def initialize(message = "token exceeds max_token_size", filename: nil, byte_pos: nil, line: nil, text: nil,
                     rule: nil)
        @code = CODE
        @rule = rule
        diagnostic = Diagnostics.error(
          CODE,
          message,
          help: "increase max_token_size or split the input token",
          note: rule.nil? ? nil : "rule #{rule} at byte #{byte_pos}"
        )
        super(message, filename: filename, byte_pos: byte_pos, line: line, text: text, diagnostic: diagnostic)
      end
    end

    class ResourceLimitError < LexError
      attr_reader :code, :rule

      def initialize(code, message, help:, filename: nil, byte_pos: nil, line: nil, text: nil, rule: nil)
        @code = code
        @rule = rule
        diagnostic = Diagnostics.error(code, message, help: help, note: rule.nil? ? nil : "rule #{rule}")
        super(message, filename: filename, byte_pos: byte_pos, line: line, text: text, diagnostic: diagnostic)
      end
    end

    class NonProgressError < ResourceLimitError
      def initialize(**context)
        super("FLEXR-E021", "lexer action did not make progress",
              help: "consume input or change to a state that can consume it", **context)
      end
    end

    class BufferTooLargeError < ResourceLimitError
      def initialize(**context)
        super("FLEXR-E022", "streaming buffer exceeds max_buffer_size",
              help: "increase max_buffer_size, shorten tokens, or use retain_input: false", **context)
      end
    end

    class StepLimitError < ResourceLimitError
      def initialize(**context)
        super("FLEXR-E023", "lexer exceeds max_steps",
              help: "increase max_steps or simplify the specification", **context)
      end
    end

    class LookaheadTooLargeError < ResourceLimitError
      def initialize(**context)
        super("FLEXR-E024", "trailing context exceeds max_lookahead_size",
              help: "increase max_lookahead_size or bound the trailing context", **context)
      end
    end

    class StateStackOverflowError < ResourceLimitError
      def initialize(message = "state stack exceeds max_state_stack", **context)
        super("FLEXR-E025", message, help: "increase max_state_stack or remove recursive pushes", **context)
      end
    end

    class CancelledError < ResourceLimitError
      def initialize(**context)
        super("FLEXR-E026", "lexing was cancelled", help: "resume with a new lexer when ready", **context)
      end
    end

    class InvalidRecoveryActionError < ResourceLimitError
      def initialize(action:, **context)
        super("FLEXR-E027", "on_error returned unsupported action #{action.inspect}",
              help: "return :skip, :raise, :halt, or :token", **context)
      end
    end
  end
end
