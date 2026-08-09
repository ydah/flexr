# frozen_string_literal: true

require "flexr"

module WithRacc
  class RaccLexer < Flexr::Lexer
    emits :INTEGER, :PLUS

    rule(/[ \t\r\n]+/, skip: true)
    rule(/[0-9]+/, emit: :INTEGER)
    rule(/\+/, emit: :PLUS)
  end
end
