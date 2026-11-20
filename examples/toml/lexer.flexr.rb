# frozen_string_literal: true

require "flexr"

module TomlExample
  class Lexer < Flexr::Lexer
    emits :NAME, :STRING, :NUMBER, :BOOLEAN, :EQUAL, :DOT, :COMMA,
      :LBRACKET, :RBRACKET, :LBRACE, :RBRACE
    rule(/[ \t\r\n]+/, skip: true)
    rule(/#[^\n]*/, skip: true)
    rule(/"(?:\\.|[^"\\\r\n])*"|'[^'\r\n]*'/, emit: :STRING)
    rule(/true|false/, emit: :BOOLEAN)
    rule(/[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/, emit: :NUMBER)
    rule(/[A-Za-z_][A-Za-z_0-9-]*/, emit: :NAME)
    rule(/=/, emit: :EQUAL)
    rule(/\./, emit: :DOT)
    rule(/,/, emit: :COMMA)
    rule(/\[/, emit: :LBRACKET)
    rule(/\]/, emit: :RBRACKET)
    rule(/\{/, emit: :LBRACE)
    rule(/\}/, emit: :RBRACE)
  end
end
