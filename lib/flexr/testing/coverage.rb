# frozen_string_literal: true

require_relative "../skeleton"
require_relative "../automaton/analysis" unless defined?(Flexr::Automaton::Analysis)

module Flexr
  module Testing
    class Coverage
      class RecordingInterpreter < Runtime::Interpreter
        FastDFA = Data.define(:accepts, :transitions, :ec, :start) do
          def direct = nil
        end

        RecordingRow = Data.define(:row, :state, :record) do
          def [](byte_class)
            target = row[byte_class]
            record.call(state, byte_class) if target
            target
          end
        end
        private_constant :FastDFA, :RecordingRow

        def initialize(lexer, record)
          super(lexer)
          @record = record
          @fast_machines = {}.compare_by_identity
          # Whole-token matches bypass the transition loop.
          @compiled = @compiled.dup
          @compiled.machines = @compiled.machines.transform_values do |machine|
            next machine unless machine.whole_tokens

            machine.dup.tap { |copy| copy.whole_tokens = nil }
          end
        end

        def scan(...)
          @scan_state = @lexer.state
          super
        end

        private

        def acceleration_enabled? = false
        def backup_memo_states_for(*) = nil

        def scan_fixed_source(machine, position, source)
          super(@fast_machines[machine] ||= recording_fast_machine(machine), position, source)
        end

        def recording_fast_machine(machine)
          dfa = machine.dfa
          record = method(:record_transition)
          rows = Hash.new { |cache, state| cache[state] = RecordingRow.new(dfa.transitions[state], state, record) }
          machine.dup.tap { |copy| copy.dfa = FastDFA.new(dfa.accepts, rows, dfa.ec, dfa.start) }
        end

        def transition(dfa, state, byte)
          target = super
          record_transition(state, dfa.ec.fetch(byte)) if target
          target
        end

        def record_transition(state, byte_class)
          @record.call(@scan_state, state, byte_class)
        end
      end
      private_constant :RecordingInterpreter

      def initialize(lexer_class)
        raise ArgumentError, "coverage requires a Flexr::Lexer class" unless lexer_class.is_a?(Class) && lexer_class <= Lexer

        config = lexer_class.__flexr_config
        raise ArgumentError, "transition coverage requires a DFA backend (got firstmatch)" if config.backend == :firstmatch

        @lexer_class = lexer_class
        @compiled = lexer_class.compile!
        @encoding = config.encoding
        @hits = Hash.new(0)
        @mutex = Mutex.new
      end

      def lexer(input, **)
        lexer = @lexer_class.new(input, **)
        record = method(:record_hit)
        lexer.instance_variable_set(:@generated_scanner, false)
        lexer.instance_variable_set(:@interpreter, RecordingInterpreter.new(lexer, record))
        if lexer.respond_to?(:clear_input_scanners, true)
          lexer.singleton_class.prepend(Module.new do
            define_method(:clear_input_scanners) do
              super()
              @interpreter = RecordingInterpreter.new(self, record)
            end
            private :clear_input_scanners
          end)
        end
        lexer
      end

      def report
        hits = @mutex.synchronize { @hits.dup }
        skeleton = Skeleton.new(@compiled, encoding: @encoding)
        transitions = []
        uncovered = []
        @compiled.machines.each do |state, machine|
          edges = state_transitions(state, machine.dfa, hits)
          transitions.concat(edges)
          missing = edges.select { |edge| edge.fetch(:hits).zero? }
          next if missing.empty?

          examples = skeleton.witnesses(state, missing.map { |edge| edge.values_at(:from, :byte_class) })
          missing.each do |edge|
            example = examples[edge.values_at(:from, :byte_class)]
            uncovered << (example ? edge.merge(example: example) : edge.merge(reason: uncovered_reason))
          end
        end
        { covered: transitions.size - uncovered.size, total: transitions.size, transitions: transitions, uncovered: uncovered }
      end

      private

      def record_hit(state, from, byte_class)
        @mutex.synchronize { @hits[[state, from, byte_class]] += 1 }
      end

      def state_transitions(state, dfa, hits)
        edges = []
        dfa.transitions.each_with_index do |row, from|
          row.each_with_index do |to, byte_class|
            next unless to

            edges << { state: state, from: from, byte_class: byte_class, to: to, hits: hits[[state, from, byte_class]] }
          end
        end
        edges
      end

      def uncovered_reason
        @encoding == Encoding::UTF_8 ? :no_valid_input : :unreachable
      end
    end
  end
end
