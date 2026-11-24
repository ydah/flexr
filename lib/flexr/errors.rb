# frozen_string_literal: true

module Flexr
  class Error < StandardError
    attr_reader :diagnostic, :filename, :byte_pos

    def initialize(message = nil, diagnostic: nil, filename: nil, byte_pos: nil)
      @diagnostic = diagnostic
      @filename = filename
      @byte_pos = byte_pos
      super(message || diagnostic&.message)
    end
  end

  class LexError < Error
    Continuation = Data.define(:byte_pos, :expected_bytes, :suffix, :eof)

    attr_reader :line, :text

    def initialize(message, filename: nil, byte_pos: nil, line: nil, text: nil, diagnostic: nil, continuation: nil, &details)
      @line = line
      @text = text
      @continuation = continuation
      if details
        resolved = nil
        @details = lambda do
          if details
            resolved = details.call
            details = nil
          end
          resolved
        end
      end
      super(message, diagnostic: diagnostic, filename: filename, byte_pos: byte_pos)
    end

    def continuation = @continuation || @details&.call&.first

    def diagnostic = super || @details&.call&.last
  end

  class CompileError < Error; end
  class UnsupportedRegexpError < CompileError; end
  class StaticResolutionError < CompileError; end
  class FrozenSpecificationError < Error; end
end
