# frozen_string_literal: true

module Flexr
  class Recognizer
    def initialize(compiled, config, state)
      @dfa = shareable(compiled.machines.fetch(state).dfa)
      rules = compiled.rules
      @identities = rules.map { |rule| rule.emit? ? rule.action[1] : rule.index }.freeze
      ranks = Array.new(rules.length)
      rules.sort_by { |rule| [-(rule.respond_to?(:priority) ? rule.priority : 0), rule.index] }
        .each_with_index { |rule, rank| ranks[rule.index] = rank }
      @ranks = ranks.freeze
      trailing = Array.new(rules.length)
      @dfa.rule_ids.each do |index|
        rule = rules.fetch(index)
        next unless rule.trailing

        dfa = rule.trailing_dfa || Flexr.compile_pattern(
          rule.trailing, encoding: config.encoding, options: config.options.slice(:unicode, :max_dfa_states)
        )
        trailing[index] = shareable(dfa)
      end
      @trailing = trailing.freeze
      @utf8 = config.encoding == Encoding::UTF_8
      freeze
    end

    def match(input, offset)
      raise TypeError, "recognizer input must be a String and offset an Integer" unless input.is_a?(String) && offset.is_a?(Integer)
      raise RangeError, "recognizer offset is outside the input" unless offset.between?(0, input.bytesize)
      return if offset == input.bytesize

      best_rule = best_finish = best_total = nil
      walk(@dfa, input, offset) do |rule, finish|
        dfa = @trailing[rule]
        total = dfa ? trailing_end(dfa, input, finish) : finish
        next unless total
        next if best_total && (total < best_total || (total == best_total && @ranks[rule] > @ranks[best_rule]))

        best_rule = rule
        best_finish = finish
        best_total = total
      end
      return unless best_rule

      identity = @identities.fetch(best_rule)
      block_given? ? yield(identity, best_finish) : [identity, best_finish]
    end

    private

    def shareable(dfa)
      Ractor.shareable?(dfa) ? dfa : Generated.shareable_dfa(dfa)
    end

    def trailing_end(dfa, input, start)
      ending = nil
      walk(dfa, input, start) { |_, finish| ending = finish }
      ending
    end

    def walk(dfa, input, start)
      cursor = boundary = start
      bol = start.zero? || input.getbyte(start - 1) == 0x0a
      state = dfa.starts ? dfa.start_for(Automaton::LeftContext.at(start, bol)) : dfa.start
      while state
        byte = input.getbyte(cursor)
        if cursor == boundary
          boundary = byte && scalar_end(input, cursor, byte)
          return if cursor == start && byte && !boundary

          dfa.accepts.fetch(state).each do |acceptance|
            next if acceptance.bol_only && !bol
            next if acceptance.end_anchor && !acceptance.valid_end_at?(input, cursor)

            yield acceptance.rule_index, cursor
          end
          return unless boundary
        end
        state = dfa.transition(state, byte)
        cursor += 1
      end
    end

    def scalar_end(input, cursor, first)
      return cursor + 1 if !@utf8 || first < 0x80

      second = input.getbyte(cursor + 1)
      return unless continuation?(second)
      return cursor + 2 if first.between?(0xc2, 0xdf)

      if first.between?(0xe0, 0xef)
        return if (first == 0xe0 && second < 0xa0) || (first == 0xed && second >= 0xa0)
        return cursor + 3 if continuation?(input.getbyte(cursor + 2))
      elsif first.between?(0xf0, 0xf4)
        return if (first == 0xf0 && second < 0x90) || (first == 0xf4 && second >= 0x90)
        return cursor + 4 if continuation?(input.getbyte(cursor + 2)) && continuation?(input.getbyte(cursor + 3))
      end
      nil
    end

    def continuation?(byte)
      byte && (byte & 0xc0) == 0x80
    end
  end
end
