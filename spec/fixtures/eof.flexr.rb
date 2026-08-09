# frozen_string_literal: true

require "flexr"

module EofFixture
  class Lexer < Flexr::Lexer
    rule(/[a-z]+/) { emit :WORD }
    on_eof { emit :EOF_TOKEN, :done }
  end
end
