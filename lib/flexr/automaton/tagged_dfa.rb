# frozen_string_literal: true

module Flexr
  module Automaton
    class TaggedDFA < Data.define(:byte_classes, :transitions, :acceptances, :groups, :register_count, :encoding)
      POSITION = -1

      def state_count = transitions.length

      def cursor
        Cursor.new(self)
      end

      class Cursor
        def initialize(program)
          @program = program
          @state = 0
          @registers = Array.new(program.register_count)
          @scratch = Array.new(program.register_count)
        end

        def advance(byte, position)
          return unless @state

          step = @program.transitions.fetch(@state).fetch(@program.byte_classes.fetch(byte))
          unless step
            @state = nil
            return
          end

          @state, moves = step
          if moves
            moves.each_with_index { |source, register| @scratch[register] = offset(source, position) }
            @registers, @scratch = @scratch, @registers
          end
          self
        end

        def capture_ranges(position)
          return unless @state

          acceptance = @program.acceptances.fetch(@state)
          return unless acceptance

          @program.groups.transform_values do |occurrences|
            capture_range(acceptance, occurrences, position)
          end
        end

        private

        def capture_range(acceptance, occurrences, position)
          occurrences.reverse_each do |group|
            starting = offset(acceptance.fetch(2 * group), position)
            ending = offset(acceptance.fetch((2 * group) + 1), position)
            return starting...ending if starting && ending
          end
          nil
        end

        def offset(source, position)
          return if source.nil?

          source == POSITION ? position : @registers.fetch(source)
        end
      end
      private_constant :Cursor
    end
  end
end
