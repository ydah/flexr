# frozen_string_literal: true

require "flexr"

module WithLrama
  class LramaLexer < Flexr::Lexer
    emits :INTEGER, :MINUS

    rule(/[ \t\r\n]+/, skip: true)
    rule(/[0-9]+/, emit: :INTEGER)
    rule(/-/, emit: :MINUS)
  end
end
