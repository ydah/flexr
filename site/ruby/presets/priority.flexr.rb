# frozen_string_literal: true

class Lexer < Flexr::Lexer
  rule(/[ \t\n]+/, skip: true)
  rule(/[a-z]+/, emit: :IDENT)
  rule("if", emit: :IF, priority: 10)
end
