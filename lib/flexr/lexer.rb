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

    def self.parallel_tokens(input, workers: 2, min_bytes: 1_048_576, filename: nil)
      Runtime::Parallel.tokens(self, input, workers: workers, min_bytes: min_bytes, filename: filename)
    end
  end
end
