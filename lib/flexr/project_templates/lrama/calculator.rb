# frozen_string_literal: true

require "open3"
require_relative "lexer.flexr"

module Calculator
  PARSER = File.expand_path("build/calculator_parser", __dir__)

  def self.evaluate(source)
    tokens = CalculatorLexer.new(source).each_token.map do |kind, value|
      kind == :INTEGER ? "n#{value}\n" : value
    end.join
    output, error, status = Open3.capture3([PARSER, PARSER], stdin_data: tokens, binmode: true)
    raise ArgumentError, error.strip unless status.success?

    Integer(output, 10)
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
