# frozen_string_literal: true

module Flexr
  module Codegen
    class Base
      attr_reader :compiled

      def initialize(compiled)
        @compiled = compiled
      end

      def stats
        compiled.stats
      end
    end
  end
end
