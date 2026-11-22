# frozen_string_literal: true

require_relative "lexer.flexr"
require_relative "build/parser"

module Calculator
  def self.evaluate(source)
    CalculatorParser.new.parse(CalculatorLexer.new(source))
  rescue Racc::ParseError => e
    raise ArgumentError, e.message
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby calculator.rb '12 + 3 - 4'" unless ARGV.length == 1

  begin
    puts Calculator.evaluate(ARGV.first)
  rescue ArgumentError, Flexr::LexError => e
    abort e.message
  end
end
