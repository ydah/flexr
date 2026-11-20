# frozen_string_literal: true

module Flexr
  module Runtime
    Token = Data.define(:type, :value, :location) do
      include Record

      def initialize(type: nil, value: nil, location: nil)
        super
      end
    end
  end
end
