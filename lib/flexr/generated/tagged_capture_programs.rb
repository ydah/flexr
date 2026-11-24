# frozen_string_literal: true

module Flexr
  module Generated
    module TaggedCapturePrograms
      def __flexr_add_generated_rule(definition)
        payload = definition[:tagged_capture_program_data]
        return super unless payload

        programs = payload.map { |program| load_tagged_capture_program(program) if program }.freeze
        super(definition.merge(tagged_capture_programs: programs))
      end

      private

      def load_tagged_capture_program(data)
        encoding = Encoding.find(data.fetch(:encoding))
        whole_capture = data[:whole_capture]
        return Automaton::TaggedDFA::WholeCapture.new(whole_capture: whole_capture.freeze, encoding: encoding) if whole_capture

        byte_classes = data.fetch(:byte_classes).freeze
        class_count = byte_classes.last + 1
        rows = data.fetch(:rows).map do |runs|
          row = Array.new(class_count)
          runs.each do |first, last, target, moves|
            row.fill([target, moves&.freeze].freeze, first..last)
          end
          row.freeze
        end.freeze
        Automaton::TaggedDFA.new(
          byte_classes: byte_classes, transitions: rows, acceptances: data.fetch(:acceptances).each(&:freeze).freeze,
          groups: data.fetch(:groups).transform_values(&:freeze).freeze, register_count: data.fetch(:register_count),
          encoding: encoding, whole_capture: nil
        )
      end
    end
  end

  DSL.prepend(Generated::TaggedCapturePrograms)
end
