# frozen_string_literal: true

require "flexr"

module RubySubset
  class Lexer < Flexr::Lexer
    KEYWORDS = %w[class def end].freeze
    IDENT = /[A-Za-z_][A-Za-z_0-9]*/

    emits :KEYWORD, :IDENT, :STRING

    rule(/[ \t\r\n]+/, skip: true)
    rule(KEYWORDS) { emit :KEYWORD, text.to_sym }
    rule(IDENT) { emit :IDENT, "#{text}:identifier" }
    rule(/"(?:\\.|[^"\\])*"/) do
      value = <<~TOKEN
        #{text[1...-1]}
      TOKEN
      emit :STRING, value.chomp
    end
  end
end
