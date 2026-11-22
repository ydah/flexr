# frozen_string_literal: true

class Lexer < Flexr::Lexer
  IDENTIFIER = pattern(/[a-z_][a-z0-9_]*/)

  rule(/[ \t\n]+/, skip: true)
  rule(IDENTIFIER, emit: :IDENT)
  keywords %w[if else end], among: :IDENT
end
