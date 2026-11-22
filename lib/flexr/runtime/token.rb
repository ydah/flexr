# frozen_string_literal: true

module Flexr
  module Runtime
    EMPTY_TRIVIA = [].freeze

    Token = Data.define(:type, :value, :location) do
      include Record

      def initialize(type: nil, value: nil, location: nil)
        super
      end

      def channel = :default

      def leading_trivia = EMPTY_TRIVIA
    end
  end
end
