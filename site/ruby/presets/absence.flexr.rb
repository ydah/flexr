# frozen_string_literal: true

class Lexer < Flexr::Lexer
  rule(%r{/\*(?~\*/)\*/}, skip: true)
  rule(/[ \t\r\n]+/, skip: true)
  rule(/[a-z][a-z0-9_]*/, emit: :IDENT)
end
