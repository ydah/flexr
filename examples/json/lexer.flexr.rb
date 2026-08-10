# frozen_string_literal: true

require "flexr"

module JsonExample
  class Lexer < Flexr::Lexer
    backend :direct
    emits :LBRACE, :RBRACE, :LBRACKET, :RBRACKET, :COLON, :COMMA,
      :STRING, :NUMBER, :TRUE, :FALSE, :NULL

    rule(/[ \t\r\n]+/, skip: true)
    rule(/\{/) { emit :LBRACE }
    rule(/\}/) { emit :RBRACE }
    rule(/\[/) { emit :LBRACKET }
    rule(/\]/) { emit :RBRACKET }
    rule(/:/) { emit :COLON }
    rule(/,/) { emit :COMMA }
    rule(/true/) { emit :TRUE, true }
    rule(/false/) { emit :FALSE, false }
    rule(/null/) { emit :NULL, nil }
    rule(/-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/) { emit :NUMBER, text.to_f }
    rule(/"(?:\\.|[^"\\])*"/) { emit :STRING, text.byteslice(1...-1) }
  end
end
