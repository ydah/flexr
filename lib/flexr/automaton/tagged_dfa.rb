# frozen_string_literal: true

module Flexr
  module Automaton
    unless const_defined?(:TaggedDFA, false)
      class TaggedDFA < Data.define(:byte_classes, :transitions, :acceptances, :groups, :register_count, :encoding, :whole_capture)
        POSITION = -1
        WholeCapture = Data.define(:whole_capture, :encoding)

        def state_count = transitions.length

        def cursor
          Cursor.new(self)
        end

        def capture_ranges(acceptance, registers, position)
          groups.transform_values do |occurrences|
            capture_range(occurrences, acceptance, registers, position)
          end
        end

        Snapshot = Data.define(:program, :acceptance, :registers, :position) do
          def ranges
            program.capture_ranges(acceptance, registers, position)
          end
        end
        private_constant :Snapshot

        class Cursor
          def initialize(program)
            @program = program
            @byte_classes = program.byte_classes
            @transitions = program.transitions
            @registers = Array.new(program.register_count)
            @scratch = Array.new(program.register_count)
            reset
          end

          def reset
            @state = 0
            @saved_acceptance = @saved_registers = @saved_position = nil
            self
          end

          def advance(byte, position)
            return unless @state

            step = @transitions[@state][@byte_classes[byte]]
            unless step
              @state = nil
              return
            end

            @state, moves = step
            if moves
              # A later probe can overwrite the bank from the selected endpoint.
              @saved_registers = @saved_registers.dup if @scratch.equal?(@saved_registers)
              moves.each_with_index do |source, register|
                @scratch[register] = source == POSITION ? position : @registers.fetch(source)
              end
              @registers, @scratch = @scratch, @registers
            end
            self
          end

          def remember(position)
            @saved_acceptance = @state && @program.acceptances.fetch(@state)
            return unless @saved_acceptance

            @saved_registers = @registers
            @saved_position = position
            self
          end

          def snapshot
            return unless @saved_acceptance

            Snapshot.new(@program, @saved_acceptance, @saved_registers.dup.freeze, @saved_position)
          end

          def capture_ranges(position)
            acceptance = @state && @program.acceptances.fetch(@state)
            return unless acceptance

            @program.capture_ranges(acceptance, @registers, position)
          end
        end
        private_constant :Cursor

        private

        def capture_range(occurrences, acceptance, registers, position)
          occurrences.reverse_each do |group|
            starting = offset(acceptance.fetch(2 * group), registers, position)
            ending = offset(acceptance.fetch((2 * group) + 1), registers, position)
            return starting...ending if starting && ending
          end
          nil
        end

        def offset(source, registers, position)
          return if source.nil?

          source == POSITION ? position : registers.fetch(source)
        end
      end
    end
  end
end
