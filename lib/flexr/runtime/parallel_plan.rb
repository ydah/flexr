# frozen_string_literal: true

module Flexr
  module Runtime
    class ParallelPlan
      Seed = Data.define(:position, :line, :column)
      Chunk = Data.define(:seeds, :limit, :certified)
      SHARED_FIELDS = %i[
        @__flexr_config @__flexr_states @__flexr_eof_rules
        @__flexr_generated_actions @__flexr_generated_eof_actions
      ].freeze
      private_constant :SHARED_FIELDS

      attr_reader :lexer_class, :chunks

      def initialize(lexer_class, input, workers:)
        compiled = lexer_class.compile!
        @lexer_class = shareable_lexer(lexer_class, compiled)
        @bytes = input.b
        @utf8 = lexer_class.__flexr_config.encoding == Encoding::UTF_8
        machine = compiled.machines.fetch(:initial)
        @dfa = machine.dfa
        @cut_classes = {}
        @chunks = plan_chunks([workers, @bytes.bytesize].min, search_window(machine))
      end

      private

      def shareable_lexer(original, compiled)
        rules = compiled.rules.map do |rule|
          IR::Rule.new(**rule.to_h, trailing_dfa: rule.trailing_dfa && shareable_dfa(rule.trailing_dfa))
        end
        machines = compiled.machines.transform_values do |machine|
          Automaton::Machine.new(**machine.to_h, dfa: shareable_dfa(machine.dfa))
        end
        copy = Automaton::CompiledSpec.new(**compiled.to_h, machines: machines, rules: rules)
        fields = SHARED_FIELDS.to_h { |name| [name, original.instance_variable_get(name)] }
        fields[:@__flexr_compiled] = copy
        fields[:@__flexr_rules] = rules
        original.dup.tap do |substitute|
          Ractor.make_shareable(fields, copy: true).each do |name, value|
            substitute.instance_variable_set(name, value)
          end
        end
      end

      def shareable_dfa(dfa)
        dfa.transitions.is_a?(Array) ? dfa : Generated.shareable_dfa(dfa)
      end

      def search_window(machine)
        backup = machine.push_backup_bytes
        backup = Automaton::Analysis.backup(@dfa, witness: false).maximum_bytes if backup.nil? && defined?(Automaton::Analysis)
        256 + [backup || 0, 3_840].min
      end

      def plan_chunks(workers, window)
        size = @bytes.bytesize
        cuts = [[0, true]]
        (1...workers).each do |index|
          nominal = (size * index) / workers
          first = cuts.last.first + 1
          last = ((size * (index + 1)) / workers) - 1
          cut = nearest_certified_cut(nominal, [nominal - window, first].max, [nominal + window, last].min)
          position = cut || character_boundary([nominal, first].max)
          cuts << [position, !cut.nil?] if position <= last
        end

        groups = cuts.each_with_index.map do |(position, certified), index|
          limit = cuts[index + 1]&.first
          starts = [position]
          alternative = character_boundary(position + 1) unless certified
          starts << alternative if alternative && alternative < (limit || size)
          [starts, limit, certified]
        end
        seeds = locate_seeds(groups.flat_map(&:first).uniq.sort)
        groups.map do |positions, limit, certified|
          Chunk.new(positions.map { |position| seeds.fetch(position) }.freeze, limit, certified)
        end.freeze
      end

      def nearest_certified_cut(nominal, first, last)
        return if first > last

        chosen = nil
        window = @bytes.byteslice((first - 1)...last)
        lf = window.byteindex("\n")
        while lf
          position = first + lf
          distance = (position - nominal).abs
          break if chosen && distance >= (chosen - nominal).abs && position > nominal

          following = @bytes.getbyte(position)
          chosen = position if character_boundary(position) == position && cut_after_lf?(following)
          lf = window.byteindex("\n", lf + 1)
        end
        chosen
      end

      def cut_after_lf?(following)
        column = @dfa.ec.fetch(following)
        @cut_classes.fetch(column) do
          @cut_classes[column] = lf_destinations.none? do |state|
            target = @dfa.transitions.fetch(state)[column]
            target && @viable[target]
          end
        end
      end

      def lf_destinations
        @lf_destinations ||= begin
          predecessors = Array.new(@dfa.states) { [] }
          @dfa.transitions.each_with_index do |row, state|
            row.compact.uniq.each { |target| predecessors[target] << state }
          end
          viable = @dfa.accepts.each_index.reject { |state| @dfa.accepts.fetch(state).empty? }
          @viable = Array.new(@dfa.states, false)
          viable.each { |state| @viable[state] = true }
          viable.each do |state|
            predecessors[state].each do |previous|
              next if @viable[previous]

              @viable[previous] = true
              viable << previous
            end
          end
          lf_column = @dfa.ec.fetch(0x0a)
          viable.filter_map { |state| @dfa.transitions.fetch(state)[lf_column] }.uniq
        end
      end

      def character_boundary(position)
        if @utf8
          while (byte = @bytes.getbyte(position)) && (byte & 0xc0) == 0x80
            position += 1
          end
        end
        position
      end

      def locate_seeds(positions)
        previous = 0
        line = column = 1
        positions.to_h do |position|
          segment = @bytes.byteslice(previous...position)
          if (lf = segment.rindex("\n"))
            line += segment.count("\n")
            column = 1
            segment = segment.byteslice((lf + 1)..)
          end
          column += @utf8 ? segment.force_encoding(Encoding::UTF_8).length : segment.bytesize
          previous = position
          [position, Seed.new(position, line, column)]
        end
      end
    end
  end
end
