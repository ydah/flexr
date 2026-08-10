# frozen_string_literal: true

require "flexr"

module Flexr
  module Regexp
    # This specification is intentionally small: it is a dogfood target for
    # the source lexer path, not the parser's implementation.
    class SourceLexer < Flexr::Lexer
      encoding Encoding::BINARY
      emits :PROPERTY, :ESCAPE, :CHAR_CLASS, :QUANTIFIER, :ALTERNATION,
        :GROUP_OPEN, :GROUP_CLOSE, :ANCHOR, :DOT, :LITERAL

      rule(/[ \t\r\n]+/, skip: true)
      rule(/\\p\{[A-Za-z_][A-Za-z0-9_]*\}/) { emit :PROPERTY, text.byteslice(3...-1) }
      rule(/\\./) { emit :ESCAPE, text }
      rule(/\[[^\]\n]*\]/) { emit :CHAR_CLASS, text }
      rule(/[?*+]|\{[0-9]+(?:,[0-9]*)?\}/) { emit :QUANTIFIER, text }
      rule(/\|/) { emit :ALTERNATION, text }
      rule(/\(/) { emit :GROUP_OPEN, text }
      rule(/\)/) { emit :GROUP_CLOSE, text }
      rule(/\^|\$/) { emit :ANCHOR, text }
      rule(/\./) { emit :DOT, text }
      rule(/[^\\\[\]().|?*+{}^$ \t\r\n]/) { emit :LITERAL, text }
    end
  end
end
