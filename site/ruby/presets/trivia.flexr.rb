# frozen_string_literal: true

class Lexer < Flexr::Lexer
  token_kind :struct
  rule(/#[^\n]*/, channel: :comment)
  rule(/\s+/, channel: :whitespace)
  rule(/[a-z_]+/, emit: :WORD)
end
