# frozen_string_literal: true

module Flexr
  module Automaton
    Acceptance = Struct.new(:rule_index, :pattern_index, :bol_only, :end_anchor, keyword_init: true) do
      def valid_end?(byte)
        !end_anchor || byte.nil? || byte == 0x0a
      end

      def valid_end_at?(input, cursor, *)
        !end_anchor || valid_end?(input.getbyte(cursor))
      end

      def inspect
        to_a.inspect
      end
    end

    CompiledSpec = Struct.new(:machines, :rules, :states, :stats, :diagnostics, keyword_init: true)
    Machine = Struct.new(:dfa, :state_name, :whole_tokens, :residuals, :backup_memo_states,
                         :backup_recovery_states, :push_backup_bytes, keyword_init: true)
  end
end
