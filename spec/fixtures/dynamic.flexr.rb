# frozen_string_literal: true

require "flexr"

module DynamicFixture
  class Lexer < Flexr::Lexer
    PREFIX = ENV.fetch("FLEXR_PREFIX", "a")
    rule(Regexp.new(PREFIX)) { emit :PREFIX }
  end
end
