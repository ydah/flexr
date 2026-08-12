# frozen_string_literal: true

module Flexr
  module Automaton
    Acceptance = Struct.new(:rule_index, :pattern_index, :bol_only, :end_anchor, keyword_init: true) do
      def inspect
        [rule_index, pattern_index, bol_only, end_anchor].inspect
      end
    end

    CompiledSpec = Struct.new(:machines, :rules, :states, :stats, :diagnostics, keyword_init: true)
    Machine = Struct.new(:dfa, :state_name, keyword_init: true)
  end
end
