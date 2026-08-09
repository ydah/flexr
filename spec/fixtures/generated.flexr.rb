# frozen_string_literal: true

require "flexr"

module GeneratedFixture
  class Lexer < Flexr::Lexer
    DIGIT = /[0-9]/
    rule(/#{DIGIT}+/) { emit :INT, text.to_i }
  end
end
