# frozen_string_literal: true

require "flexr"

module ToyLang
  class Lexer < Flexr::Lexer
    DIGIT = /[0-9]/
    IDENT = /[A-Za-z_]/

    emits :INT, :IDENT, :PLUS, :STRING

    rule(/[ \t\r\n]+/, skip: true)
    rule(/#{DIGIT}+/) { emit :INT, text.to_i }
    rule(/#{IDENT}[A-Za-z_0-9]*/) { emit :IDENT, text }
    rule(/\+/) { emit :PLUS }
    rule(/"(?:\\.|[^"\\])*"/) { emit :STRING, text[1...-1] }
  end
end
