# frozen_string_literal: true

module Flexr
  module Automaton
    module LeftContext
      SOURCE_START = 0
      AFTER_LF = 1
      OTHER = 2
      STATES = [SOURCE_START, AFTER_LF, OTHER].freeze

      def self.at(position, bol)
        return SOURCE_START if position.zero?

        bol ? AFTER_LF : OTHER
      end

      def self.after(byte)
        byte == 0x0a ? AFTER_LF : OTHER
      end
    end
  end
end
