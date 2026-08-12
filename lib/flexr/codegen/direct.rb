# frozen_string_literal: true

module Flexr
  module Codegen
    class Direct < Table
      def generate(state: :initial)
        dfa = compiled.machines.fetch(state).dfa
        {
          nxt: dfa.transitions.flatten.map { |value| value || -1 }.freeze,
          classes: dfa.class_count
        }.freeze
      end

    end
  end
end
