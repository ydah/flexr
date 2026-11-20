# frozen_string_literal: true

module Flexr
  module Codegen
    class Firstmatch < Base
      def generate
        compiled.rules.flat_map(&:patterns).freeze
      end
    end
  end
end
