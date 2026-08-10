# frozen_string_literal: true

require "flexr"

module CalculatorExample
  class Lexer < Flexr::Lexer
    emits :EQ, :ASSIGN, :IF, :IDENT, :INTEGER, :PLUS

    rule(/[ \t\r\n]+/, skip: true)
    rule(/==/) { emit :EQ }
    rule(/=/) { emit :ASSIGN }
    rule(/if/) { emit :IF }
    rule(/[a-z_][a-z0-9_]*/) { emit :IDENT }
    rule(/[0-9]+/) { emit :INTEGER, text.to_i }
    rule(/\+/) { emit :PLUS }
  end
end
