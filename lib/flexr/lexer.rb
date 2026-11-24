# frozen_string_literal: true

module Flexr
  class Lexer
    extend DSL
    include Runtime

    __flexr_reset!

    def self.push(**)
      Runtime::Push.new(self, **)
    end

    def self.incremental(input, **)
      Runtime::Incremental.new(self, input, **)
    end
  end
end
