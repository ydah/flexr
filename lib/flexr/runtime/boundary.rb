# frozen_string_literal: true

module Flexr
  module Runtime
    Boundary = Data.define(:position, :line, :column, :state, :stack, :dfa_start, :bol, :left_context, :layout) do
      def converges?(old, delta:)
        position == old.position + delta && position.zero? == old.position.zero? &&
          state == old.state && stack == old.stack && dfa_start == old.dfa_start &&
          bol == old.bol && left_context == old.left_context && layout == old.layout
      end
    end
  end
end
