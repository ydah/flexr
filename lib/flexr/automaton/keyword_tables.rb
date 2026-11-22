# frozen_string_literal: true

module Flexr
  module Automaton
    module KeywordTables
      module_function

      def diagnostics(compiled, spec)
        spec.options.fetch(:keyword_tables, {}).flat_map do |among, entries|
          targets = compiled.rules.select { |rule| rule.emit? && !rule.channel && rule.action[1] == among }
          entries.filter_map do |spelling, (_, location)|
            matched = compiled.machines.values.filter_map do |machine|
              accepts = full_acceptances(machine.dfa, spelling)
              candidates = targets.select do |rule|
                accepts.any? { |acceptance| acceptance.rule_index == rule.index } &&
                  full_firstmatch?(rule, spelling, spec)
              end
              [accepts, candidates] unless candidates.empty?
            end
            if matched.empty?
              Keywords.error!(
                "no default-channel rule with emit: #{among.inspect} accepts the full keyword",
                location: location, note: "input #{spelling.inspect}",
                help: "add or widen a default-channel rule with emit: #{among.inspect} to match the entire spelling"
              )
            end
            next unless matched.all? { |accepts, candidates| shadowed?(compiled, accepts, candidates) }

            Diagnostics.warning(
              "FLEXR-W022", "keyword #{spelling.inspect} never reaches emit: #{among.inspect}",
              location: location, note: "an earlier rule wins on input #{spelling.inspect}",
              help: "remove the redundant keyword or change the competing rule"
            )
          end
        end
      end

      def full_firstmatch?(rule, spelling, spec)
        spec.backend != :firstmatch ||
          Analysis.firstmatch_length(rule, spelling, encoding: spec.encoding, unicode: spec.options[:unicode] == true) == spelling.bytesize
      end

      def shadowed?(compiled, accepted, candidates)
        return false if candidates.any?(&:trailing)

        target = candidates.map(&:index).min
        accepted.any? do |acceptance|
          acceptance.rule_index < target && !acceptance.bol_only && !acceptance.end_anchor &&
            !compiled.rules.fetch(acceptance.rule_index).trailing
        end
      end

      def grouping_suggestions(compiled, tables)
        pending = []
        compiled.rules.filter_map do |rule|
          if literal_keyword?(rule)
            pending << rule
            next
          end

          literals = pending
          pending = []
          next unless literals.length >= 2 && groupable?(compiled, rule, literals, tables)

          among = rule.action[1]
          spellings = literals.map { |literal| literal.patterns.first }.uniq
          Diagnostics.info(
            "FLEXR-I003", "#{literals.length} consecutive literal rules can share an identifier rule",
            location: literals.first.location,
            help: "replace them with keywords #{spellings.inspect}, among: #{among.inspect}",
            note: "input #{spellings.first.inspect} also matches rule #{rule.index}"
          )
        end
      end

      def literal_keyword?(rule)
        spelling = rule.patterns.first
        return false unless rule.emit? && !rule.channel && !rule.trailing && rule.patterns.one?
        return false unless spelling.is_a?(String) && !spelling.empty?

        normalized = Keywords.spelling(spelling)
        normalized.valid_encoding? && rule.action[1] == normalized.upcase.to_sym
      end

      def groupable?(compiled, rule, literals, tables)
        return false unless rule.emit? && !rule.channel && !rule.trailing && rule.patterns.all?(::Regexp)
        return false unless literals.all? { |literal| literal.states == rule.states }
        return false if tables&.key?(rule.action[1])
        return false if tables && literals.any? { |literal| tables.key?(literal.action[1]) }
        return false unless compiled.rules.one? { |entry| entry.emit? && !entry.channel && entry.action[1] == rule.action[1] }

        literals.all? do |literal|
          compiled.machines.values.all? do |machine|
            next true unless machine.dfa.rule_ids.include?(literal.index)

            full_acceptances(machine.dfa, literal.patterns.first).any? do |acceptance|
              acceptance.rule_index == rule.index && !acceptance.bol_only && !acceptance.end_anchor
            end
          end
        end
      end

      def full_acceptances(dfa, spelling)
        state = dfa.start
        spelling.each_byte do |byte|
          state = dfa.transition(state, byte)
          return [] unless state
        end
        dfa.accepts.fetch(state)
      end
    end
  end
end
