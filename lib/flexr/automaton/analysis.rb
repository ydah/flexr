# frozen_string_literal: true

module Flexr
  module Automaton
    module Analysis
      module_function

      def unreachable_rules(compiled)
        present = compiled.machines.values.flat_map { |machine| machine.dfa.rule_ids }.uniq
        compiled.rules.reject { |rule| present.include?(rule.index) }
      end

      def needs_backup?(dfa)
        dfa.transitions.each_index.any? do |state|
          next false if dfa.accepts[state].empty?

          dfa.transitions[state].compact.any? { |destination| dfa.accepts[destination].empty? }
        end
      end

      def self_loop_set(dfa, state)
        Accel.self_loop_set(dfa, state)
      end

      def dead_states(dfa)
        dfa.transitions.each_index.select do |state|
          dfa.accepts[state].empty? && dfa.transitions[state].compact.all? { |destination| destination == state }
        end
      end

      def firstmatch_counterexample(first, second)
        queue = [[first.start, second.start, false, +"".b]]
        visited = { [first.start, second.start, false] => true }
        bytes = joint_byte_representatives(first, second)
        cursor = 0

        while cursor < queue.length
          first_state, second_state, first_seen, input = queue.fetch(cursor)
          cursor += 1
          bytes.each do |byte|
            next_first = first_state && first.transition(first_state, byte)
            next_second = second_state && second.transition(second_state, byte)
            next unless next_second

            next_input = input + byte.chr(Encoding::BINARY)
            next_first_seen = first_seen || accepting?(first, next_first)
            return next_input if next_first_seen && accepting?(second, next_second) && !accepting?(first, next_first)

            key = [next_first, next_second, next_first_seen]
            next if visited[key]

            visited[key] = true
            queue << [next_first, next_second, next_first_seen, next_input]
          end
        end
        nil
      end

      def joint_byte_representatives(first, second)
        representatives = {}
        256.times do |byte|
          key = [first.ec[byte], second.ec[byte]]
          representatives[key] ||= byte
        end
        representatives.values.sort_by { |byte| [byte.between?(32, 126) ? 0 : 1, byte] }
      end

      def shadowing_examples(dfa, rule_indices, include_empty: false)
        remaining = (rule_indices & dfa.rule_ids).to_h { |index| [index, true] }
        return {} if remaining.empty?

        examples = {}
        queue = [[dfa.start, nil, nil]]
        # Visiting the start again permits a nonempty example when it accepts and loops.
        visited = {}
        bytes = joint_byte_representatives(dfa, dfa)
        cursor = 0
        while cursor < queue.length
          state = queue.fetch(cursor).first
          accepts = dfa.accepts.fetch(state)
          winner = accepts.min_by(&:rule_index)&.rule_index
          if (include_empty || cursor.positive?) && winner
            shadowed = accepts.map(&:rule_index).uniq.select { |index| index > winner && remaining.key?(index) }
            unless shadowed.empty?
              input = example_input(queue, cursor)
              shadowed.each do |index|
                examples[index] = [input, winner]
                remaining.delete(index)
              end
              return examples if remaining.empty?
            end
          end

          bytes.each do |byte|
            target = dfa.transition(state, byte)
            next if target.nil? || visited[target]

            visited[target] = true
            queue << [target, cursor, byte]
          end
          cursor += 1
        end
        examples
      end

      def example_input(paths, cursor)
        bytes = []
        while (parent = paths.fetch(cursor)[1])
          bytes << paths.fetch(cursor)[2]
          cursor = parent
        end
        bytes.reverse.pack("C*")
      end

      def shortest_input(dfa)
        queue = [[dfa.start, nil, nil]]
        visited = { dfa.start => true }
        bytes = joint_byte_representatives(dfa, dfa)
        cursor = 0
        while cursor < queue.length
          state = queue.fetch(cursor).first
          return example_input(queue, cursor) if accepting?(dfa, state)

          bytes.each do |byte|
            target = dfa.transition(state, byte)
            next if target.nil? || visited[target]

            visited[target] = true
            queue << [target, cursor, byte]
          end
          cursor += 1
        end
        nil
      end

      def trailing_example(dfa, rules, target, input, trailing_dfas, encoding:, unicode:, firstmatch:)
        lengths = if firstmatch
          rules.filter_map do |rule|
            next if rule.index > target.index

            length = firstmatch_length(rule, input, encoding: encoding, unicode: unicode)
            [rule.index, length] if length
          end
        else
          dfa_match_lengths(dfa, input, encoding: encoding)
        end
        matches = {}
        lengths.each do |index, length|
          trailing = trailing_dfas[index]
          lookahead = trailing ? dfa_match_lengths(trailing, input, offset: length).map(&:last).max : 0
          next unless lookahead

          total = length + lookahead
          next if matches[index] && matches[index].last > total

          matches[index] = [length, total]
        end
        return unless matches.key?(target.index)

        winner, (length, total) = matches.max_by { |index, (_, size)| firstmatch ? -index : [size, -index] }
        [winner, length, total - length]
      rescue EncodingError
        nil
      end

      def dfa_match_lengths(dfa, input, offset: 0, encoding: Encoding::BINARY)
        state = dfa.start
        cursor = offset
        matches = []
        loop do
          if encoding != Encoding::UTF_8 || input.byteslice(0, cursor).valid_encoding?
            dfa.accepts.fetch(state).each do |acceptance|
              next if acceptance.end_anchor && cursor < input.bytesize && input.getbyte(cursor) != 0x0a

              matches << [acceptance.rule_index, cursor - offset]
            end
          end
          break if cursor == input.bytesize

          state = dfa.transition(state, input.getbyte(cursor))
          break unless state

          cursor += 1
        end
        matches
      end

      def firstmatch_example(rules, target, input, encoding:, unicode: false, same_length: false)
        target_length = firstmatch_length(target, input, encoding: encoding, unicode: unicode)
        return unless target_length

        rules.sort_by(&:index).each do |rule|
          break if rule.index >= target.index

          length = firstmatch_length(rule, input, encoding: encoding, unicode: unicode)
          next unless length

          return nil if same_length && length != target_length

          return [rule.index, length]
        end
        [target.index, target_length]
      rescue EncodingError
        nil
      end

      def firstmatch_length(rule, input, encoding:, unicode:)
        matches = rule.patterns.each_with_index.filter_map do |pattern, index|
          regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(::Regexp.escape(pattern.to_s))
          reference = Regexp::Matcher.reference?(regexp, encoding: encoding, unicode: unicode)
          match = Regexp::Matcher.match(regexp, input, encoding: encoding, unicode: unicode, reference: reference)
          next unless match&.begin(0)&.zero?

          [match[0].bytesize, rule.pattern_conditions.fetch(index)]
        end
        length, condition = matches.max_by(&:first)
        return unless length
        return if encoding == Encoding::UTF_8 && !input.byteslice(0, length).valid_encoding?
        return if condition.end_anchor && length < input.bytesize && input.getbyte(length) != 0x0a

        length
      end

      def accepting?(dfa, state)
        state && !dfa.accepts.fetch(state).empty?
      end
    end
  end
end
