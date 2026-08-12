# frozen_string_literal: true

module Flexr
  class Error < StandardError
    attr_reader :diagnostic

    def initialize(message = nil, diagnostic: nil)
      @diagnostic = diagnostic
      super(message || diagnostic&.message)
    end
  end

  class LexError < Error
    attr_reader :filename, :byte_pos, :line, :text

    def initialize(message, filename: nil, byte_pos: nil, line: nil, text: nil, diagnostic: nil)
      @filename = filename
      @byte_pos = byte_pos
      @line = line
      @text = text
      super(message, diagnostic: diagnostic)
    end
  end

  class CompileError < Error; end
  class UnsupportedRegexpError < CompileError; end
  class StaticResolutionError < CompileError; end
  class FrozenSpecificationError < Error; end
end
