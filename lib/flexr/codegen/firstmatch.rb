# frozen_string_literal: true

module Flexr
  module Codegen
    class Firstmatch < Base
      def initialize(compiled, experimental: false)
        raise CompileError, "firstmatch requires option :experimental" unless experimental

        super(compiled)
      end

      def generate
        compiled.rules.map { |rule| rule.patterns }.flatten.freeze
      end
    end
  end
end
