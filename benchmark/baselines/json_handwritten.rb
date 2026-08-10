# frozen_string_literal: true

require "strscan"

module FlexrBenchmark
  class JsonHandwrittenLexer
    WHITESPACE = /[ \t\r\n]+/
    NUMBER = /-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/
    STRING = /"(?:\\.|[^"\\])*"/

    def initialize(input)
      @scanner = StringScanner.new(input)
    end

    def tokens
      result = []
      token = nil
      result << token while (token = next_token)
      result
    end

    private

    def next_token
      return if @scanner.eos?
      return next_token if @scanner.scan(WHITESPACE)

      return [:LBRACE, @scanner.matched] if @scanner.scan("{")
      return [:RBRACE, @scanner.matched] if @scanner.scan("}")
      return [:LBRACKET, @scanner.matched] if @scanner.scan("[")
      return [:RBRACKET, @scanner.matched] if @scanner.scan("]")
      return [:COLON, @scanner.matched] if @scanner.scan(":")
      return [:COMMA, @scanner.matched] if @scanner.scan(",")
      return [:TRUE, true] if @scanner.scan("true")
      return [:FALSE, false] if @scanner.scan("false")
      return [:NULL, nil] if @scanner.scan("null")
      return [:NUMBER, @scanner.matched.to_f] if @scanner.scan(NUMBER)
      return [:STRING, @scanner.matched.byteslice(1...-1)] if @scanner.scan(STRING)

      raise ArgumentError, "invalid JSON at byte #{@scanner.pos}"
    end
  end
end
