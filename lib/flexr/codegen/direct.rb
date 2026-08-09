# frozen_string_literal: true

module Flexr
  module Codegen
    class Direct < Table
      def generate(state: :initial)
        table = super
        table.merge(dispatch: :case).freeze
      end
    end
  end
end
