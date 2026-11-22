# frozen_string_literal: true

class Lexer < Flexr::Lexer
  IDENT = pattern(/[a-z]+/)
  KEYWORD = pattern("if", "end")

  rule(/[ \t\n]+/, skip: true)
  rule(IDENT - KEYWORD, emit: :IDENT)
  rule(KEYWORD, emit: :KEYWORD)
  rule(pattern("[[") + upto("aba"), emit: :BLOCK)
end
