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
        # shortcut: nonlocal assertions need a suffix product to prove first-match differences.
        return if first.lookahead? || second.lookahead?

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
            next_first_seen = if first.context_dependent_end?
              first_seen || accepting?(first, first_state, byte)
            else
              first_seen || accepting?(first, next_first)
            end
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
        split_line_feed = first.context_dependent_end? || second.context_dependent_end?
        256.times do |byte|
          key = [first.ec[byte], second.ec[byte]]
          key << (byte == 0x0a) if split_line_feed
          representatives[key] ||= byte
        end
        representatives.values.sort_by { |byte| [byte.between?(32, 126) ? 0 : 1, byte] }
      end

      def contextual_winners(dfa)
        bytes = joint_byte_representatives(dfa, dfa).map { |byte| [byte, EndContext.for_byte(byte)] }
        [true, false].flat_map do |bol|
          winners = dfa.accepts.map do |labels|
            [nil, 0x0a, 0x20].to_h do |byte|
              winner = labels.find { |label| (bol || !label.bol_only) && label.valid_end?(byte) }
              [EndContext.for_byte(byte), winner&.rule_index]
            end
          end
          rejecting = rejecting_suffixes(dfa, winners, bytes)
          winners.each_with_index.flat_map do |row, state|
            before_byte = bytes.filter_map do |byte, context|
              target = dfa.transition(state, byte)
              row.fetch(context) if target.nil? || rejecting[target]
            end
            before_byte << row.fetch(EndContext::EOF)
          end.compact
        end.uniq
      end

      # A shorter match can win only if the rest of the scan finds no match.
      def rejecting_suffixes(dfa, winners, bytes)
        parents = Array.new(dfa.states) { [] }
        queue = []
        rejecting = Array.new(dfa.states, false)
        winners.each_with_index do |row, state|
          targets = bytes.reject { |_, context| row.fetch(context) }.map { |byte, _| dfa.transition(state, byte) }.uniq
          if row.fetch(EndContext::EOF).nil? || targets.include?(nil)
            rejecting[state] = true
            queue << state
          else
            targets.each { |target| parents.fetch(target) << state }
          end
        end
        cursor = 0
        while cursor < queue.length
          parents.fetch(queue.fetch(cursor)).each do |parent|
            next if rejecting[parent]

            rejecting[parent] = true
            queue << parent
          end
          cursor += 1
        end
        rejecting
      end

      def shadowing_examples(dfa, rule_indices, include_empty: false, include_unshadowed: false)
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
          accepts = accepts.select { |label| label.valid_end?(nil) } if dfa.context_dependent_end?
          winner = accepts.first&.rule_index
          if (include_empty || cursor.positive?) && winner
            shadowed = accepts.map(&:rule_index).uniq.select do |index|
              (include_unshadowed || index != winner) && remaining.key?(index)
            end
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

      def trailing_example(dfa, rules, target, input, trailing_dfas, encoding:, unicode:, firstmatch:, same_length: false,
                           shortest: false, allow_empty_match: false)
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
          next if shortest && ((!allow_empty_match && length.zero?) || matches.key?(index))

          trailing = trailing_dfas[index]
          lookahead = trailing ? dfa_match_lengths(trailing, input, offset: length, encoding: encoding).map(&:last).max : 0
          next unless lookahead

          total = length + lookahead
          next if matches[index] && matches[index].last > total

          matches[index] = [length, total]
        end
        return unless matches.key?(target.index)

        priorities = rules.to_h { |rule| [rule.index, rule.priority] }
        winner, (length, total) = matches.max_by do |index, (body, size)|
          next -index if firstmatch

          [shortest ? -body : size, priorities.fetch(index), -index]
        end
        if same_length
          target_length = matches.fetch(target.index)
          return if shortest ? length != target_length.first : total != target_length.last
        end

        [winner, length, total - length]
      rescue EncodingError
        nil
      end

      def dfa_match_lengths(dfa, input, offset: 0, encoding: Encoding::BINARY)
        cursor = offset
        matches = []
        at_line_start = offset.zero? || input.getbyte(offset - 1) == 0x0a
        state = dfa.start_at(input, offset, at_line_start)
        loop do
          if encoding != Encoding::UTF_8 || input.byteslice(0, cursor).force_encoding(encoding).valid_encoding?
            dfa.accepts.fetch(state).each do |acceptance|
              next if acceptance.bol_only && !at_line_start
              next if acceptance.end_anchor && !acceptance.valid_end_at?(input, cursor)

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

      def accepting?(dfa, state, following_byte = nil)
        state && dfa.accepts.fetch(state).any? { |acceptance| !acceptance.end_anchor || acceptance.valid_end?(following_byte) }
      end
    end
  end
end
