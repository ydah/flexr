# frozen_string_literal: true

class Lexer < Flexr::Lexer
  token_kind :struct
  indentation newline: :NEWLINE, indent: :INDENT, dedent: :DEDENT, brackets: ["()"], tab_width: 4

  rule("if", emit: :IF)
  rule(/[a-z_][a-z_0-9]*/, emit: :IDENT)
  rule(":", emit: :COLON)
  rule(/[()]/, emit: :PAREN)
  rule(/\r?\n/, emit: :NEWLINE)
  rule(/[ \t]+/, channel: :whitespace)
  rule(/#[^\r\n]*/, channel: :comment)
end
