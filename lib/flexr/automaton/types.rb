# frozen_string_literal: true

module Flexr
  module Automaton
    module EndContext
      EOF = 1
      LF = 2
      OTHER = 4
      ANY = EOF | LF | OTHER
      EOL = EOF | LF

      def self.for_byte(byte)
        return EOF if byte.nil?

        byte == 0x0a ? LF : OTHER
      end

      def self.mask(condition)
        case condition
        when nil, false then ANY
        when true then EOL
        else condition
        end
      end

      def self.condition(mask)
        case mask
        when ANY then false
        when EOL then true
        else mask
        end
      end
    end

    Acceptance = Struct.new(:rule_index, :pattern_index, :bol_only, :end_anchor, keyword_init: true) do
      def valid_end?(byte)
        EndContext.mask(end_anchor).anybits?(EndContext.for_byte(byte))
      end

      def valid_end_at?(input, cursor, *)
        !end_anchor || valid_end?(input.getbyte(cursor))
      end

      def inspect
        [rule_index, pattern_index, bol_only, end_anchor].inspect
      end
    end

    CompiledSpec = Struct.new(:machines, :rules, :states, :stats, :diagnostics, keyword_init: true)
    Machine = Struct.new(:dfa, :state_name, :whole_tokens, :residuals, keyword_init: true)
  end
end
