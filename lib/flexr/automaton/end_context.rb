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

    module MaskedAcceptance
      def valid_end?(byte)
        return super unless end_anchor.is_a?(Integer)

        end_anchor.anybits?(EndContext.for_byte(byte))
      end
    end
    Acceptance.prepend(MaskedAcceptance)
  end
end
