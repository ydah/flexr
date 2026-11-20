# frozen_string_literal: true

require "flexr"

module GraphqlExample
  class Lexer < Flexr::Lexer
    emits :NAME, :STRING, :NUMBER, :SPREAD, :LBRACE, :RBRACE, :LPAREN,
      :RPAREN, :LBRACKET, :RBRACKET, :COLON, :EQUAL, :BANG, :DOLLAR, :AT, :PIPE, :AMP
    rule(/[ \t\r\n,]+/, skip: true)
    rule(/#[^\n]*/, skip: true)
    rule(/[A-Za-z_][A-Za-z_0-9]*/, emit: :NAME)
    rule(/-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/, emit: :NUMBER)
    rule(/"(?:\\.|[^"\\\r\n])*"/, emit: :STRING)
    rule(/\.\.\./, emit: :SPREAD)
    rule(/\{/, emit: :LBRACE)
    rule(/\}/, emit: :RBRACE)
    rule(/\(/, emit: :LPAREN)
    rule(/\)/, emit: :RPAREN)
    rule(/\[/, emit: :LBRACKET)
    rule(/\]/, emit: :RBRACKET)
    rule(/:/, emit: :COLON)
    rule(/=/, emit: :EQUAL)
    rule(/!/, emit: :BANG)
    rule(/\$/, emit: :DOLLAR)
    rule(/@/, emit: :AT)
    rule(/\|/, emit: :PIPE)
    rule(/&/, emit: :AMP)
  end
end
