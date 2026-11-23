# frozen_string_literal: true

module Flexr
  module Automaton
    class LookaheadReachability
      def initialize(dfa, encoding:, limit:)
        @dfa = dfa
        @encoding = encoding
        @limit = limit
        @winners = {}
        @witnesses = {}
        @guards = dfa.accepts.flat_map { |labels| labels.filter_map(&:end_anchor).grep(Lookahead) }.uniq
        ids = @guards.each_with_index.to_h
        @labels = dfa.accepts.map do |labels|
          labels.map do |label|
            anchor = label.end_anchor
            mask = EndContext.mask(anchor) unless anchor.is_a?(Lookahead)
            [label.rule_index, label.bol_only, mask, ids[anchor]]
          end
        end
        @bytes = 256.times.uniq do |byte|
          [dfa.ec.fetch(byte), EndContext.for_byte(byte), *@guards.map { |guard| guard.ec.fetch(byte) }]
        end
      end

      def winners
        return @dfa.rule_ids unless complete?(true) && complete?(false)

        @winners.keys
      end

      def example(rule)
        return unless (witness = @witnesses[rule])

        state, suffix = witness
        return unless (prefix = prefix_to(state))
        bytes = []
        while suffix
          byte, suffix = suffix
          bytes << byte
        end
        input = (prefix + bytes.pack("C*")).force_encoding(@encoding)
        input if !input.empty? && input.valid_encoding?
      end

      private

      # Prepending a byte determines which guard states accept the new suffix
      # and which body states can still reach a longer eligible match.
      def complete?(bol)
        initial = [@guards.map { |guard| mask_for(guard.eof) }, 0, EndContext::EOF]
        queue = [[initial, nil]]
        seen = { initial => true }
        cursor = 0
        while cursor < queue.length
          (guards, later, ending), suffix = queue.fetch(cursor)
          now = 0
          @labels.each_with_index do |row, state|
            eligible = row.filter_map do |rule, bol_only, mask, id|
              next if bol_only && !bol
              next unless mask ? mask.anybits?(ending) : guards.fetch(id).odd?

              rule
            end
            next if eligible.empty?

            bit = 1 << state
            now |= bit
            if later.anybits?(bit)
              eligible.each { |rule| @witnesses[rule] ||= [state, suffix] } if bol
            else
              @winners[eligible.first] = true
              eligible.drop(1).each { |rule| @witnesses[rule] ||= [state, suffix] } if bol
            end
          end
          return true if @winners.length == @dfa.rule_ids.length

          @bytes.each do |byte|
            next_guards = @guards.each_with_index.map do |guard, id|
              guard_predecessors(guard, byte, guards.fetch(id))
            end
            state = [next_guards, body_predecessors(byte, now | later), EndContext.for_byte(byte)]
            next if seen[state]
            return false if seen.length >= @limit

            seen[state] = true
            queue << [state, [byte, suffix]]
          end
          cursor += 1
        end
        true
      end

      def mask_for(flags)
        flags.each_with_index.reduce(0) { |mask, (accepted, state)| accepted ? mask | (1 << state) : mask }
      end

      def guard_predecessors(guard, byte, suffix)
        class_id = guard.ec.fetch(byte)
        guard.transitions.each_with_index.reduce(0) do |bits, (row, state)|
          accepts = row.is_a?(Array) ? suffix.anybits?(1 << row.fetch(class_id)) : row
          accepts ? bits | (1 << state) : bits
        end
      end

      def body_predecessors(byte, suffix)
        return 0 if suffix.zero?

        @labels.each_index.reduce(0) do |mask, state|
          target = @dfa.transition(state, byte)
          target && suffix.anybits?(1 << target) ? mask | (1 << state) : mask
        end
      end

      def prefix_to(target)
        @parents ||= begin
          states = [@dfa.start]
          parents = { @dfa.start => nil }
          states.each do |state|
            @bytes.each do |byte|
              following = @dfa.transition(state, byte)
              next if !following || parents.key?(following)

              parents[following] = [state, byte]
              states << following
            end
          end
          parents
        end
        return unless @parents.key?(target)

        bytes = []
        while (parent = @parents.fetch(target))
          target, byte = parent
          bytes << byte
        end
        bytes.reverse.pack("C*")
      end
    end
  end
end
