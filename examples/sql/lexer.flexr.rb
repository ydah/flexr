# frozen_string_literal: true

require "flexr"

module SqlExample
  class Lexer < Flexr::Lexer
    emits :KEYWORD, :NAME, :STRING, :NUMBER, :OPERATOR, :COMMA, :DOT, :SEMICOLON, :LPAREN, :RPAREN
    rule(/[ \t\r\n]+/, skip: true)
    rule(/--[^\n]*/, skip: true)
    rule(/SELECT|FROM|WHERE|AND|OR|NOT|NULL|AS|JOIN|ON|ORDER|BY|GROUP|HAVING|LIMIT|INSERT|INTO|VALUES|UPDATE|SET|DELETE/i) do
      emit :KEYWORD, text.upcase
    end
    rule(/[A-Za-z_][A-Za-z_0-9]*/, emit: :NAME)
    rule(/'(?:''|[^'])*'/, emit: :STRING)
    rule(/[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/, emit: :NUMBER)
    rule(%r{>=|<=|<>|!=|[=<>+*/-]}, emit: :OPERATOR)
    rule(/,/, emit: :COMMA)
    rule(/\./, emit: :DOT)
    rule(/;/, emit: :SEMICOLON)
    rule(/\(/, emit: :LPAREN)
    rule(/\)/, emit: :RPAREN)
  end
end
