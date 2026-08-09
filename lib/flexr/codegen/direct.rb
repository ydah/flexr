# frozen_string_literal: true

module Flexr
  module Codegen
    class Direct < Table
      def generate(state: :initial)
        table = super
        table.merge(dispatch: :case).freeze
      end

      def source(indent: "  ")
        lines = []
        lines << "#{indent}def self.__flexr_generated_direct_transition(state_name, state, byte)"
        lines << "#{indent}  case state_name"
        compiled.machines.each do |state_name, machine|
          lines << "#{indent}  when #{state_name.inspect}"
          lines << "#{indent}    class_id = case byte"
          byte_classes(machine.dfa.ec).each do |first, last, class_id|
            selector = first == last ? first.to_s : "#{first}..#{last}"
            lines << "#{indent}                 when #{selector} then #{class_id}"
          end
          lines << "#{indent}                 end"
          lines << "#{indent}    case state"
          machine.dfa.transitions.each_with_index do |row, state|
            lines << "#{indent}    when #{state}"
            lines << "#{indent}      case class_id"
            row.each_with_index do |destination, class_id|
              value = destination.nil? ? "nil" : destination
              lines << "#{indent}      when #{class_id} then #{value}"
            end
            lines << "#{indent}      else nil"
            lines << "#{indent}      end"
          end
          lines << "#{indent}    else nil"
          lines << "#{indent}    end"
        end
        lines << "#{indent}  else nil"
        lines << "#{indent}  end"
        lines << "#{indent}end"
        "#{lines.join("\n")}\n"
      end

      private

      def byte_classes(ec)
        ec.each_with_index.chunk_while { |left, right| right[0] == left[0] }.map do |run|
          [run.first[1], run.last[1], run.first[0]]
        end
      end
    end
  end
end
