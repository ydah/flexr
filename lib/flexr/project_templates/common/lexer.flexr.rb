# frozen_string_literal: true

require "flexr"

class CalculatorLexer < Flexr::Lexer
  emits :INTEGER, :PLUS, :MINUS

  rule(/[ \t\r\n]+/, skip: true)
  rule(/[0-9]+/) { emit :INTEGER, text.to_i }
  rule("+", emit: :PLUS)
  rule("-", emit: :MINUS)
end
