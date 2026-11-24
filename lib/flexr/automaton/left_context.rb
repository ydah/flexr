# frozen_string_literal: true

module Flexr
  module Automaton
    module LeftContext
      SOURCE_START = 0
      AFTER_LF = 1
      OTHER = 2
      STATES = [SOURCE_START, AFTER_LF, OTHER].freeze

      Graph = Data.define(:transitions, :ec) do
        def initialize(transitions:, ec:)
          super(transitions: transitions.map(&:freeze).freeze, ec: ec.freeze)
        end

        def transition(state, byte)
          transitions.fetch(state).fetch(ec.fetch(byte))
        end

        def advance(input, state, starting, ending)
          while starting < ending
            state = transition(state, input.getbyte(starting))
            starting += 1
          end
          state
        end
      end

      def self.at(position, bol)
        return SOURCE_START if position.zero?

        bol ? AFTER_LF : OTHER
      end

      def self.after(byte)
        byte == 0x0a ? AFTER_LF : OTHER
      end
    end

    class DFA
      def start_at(input, position, bol)
        return start unless starts

        graph = left_context
        context = if graph && input.respond_to?(:left_state_at)
          input.left_state_at(graph, position)
        elsif graph
          graph.advance(input, 0, 0, position)
        else
          LeftContext.at(position, bol)
        end
        start_for(context)
      end
    end
  end
end
