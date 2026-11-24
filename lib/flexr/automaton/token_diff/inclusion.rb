# frozen_string_literal: true

module Flexr
  module Automaton
    module TokenDiff
      module_function

      def inclusion(superset, subset, encoding:, limit: 100_000)
        utf8_rows = UTF8.rows(encoding)
        unless utf8_rows
          return Result.new(status: :inconclusive, input: nil, offset: nil, left: nil, right: nil,
                            reason: "unsupported input encoding")
        end

        raise SearchLimit if limit < 1

        bytes = BYTE_ORDER.uniq do |byte|
          [subset.ec.fetch(byte), superset.ec.fetch(byte), utf8_rows.map { |row| row.fetch(byte) }]
        end
        origin = [subset.start, superset.start, 0]
        queue = [origin]
        parents = { origin => nil }
        queue.each do |position|
          smaller_state, larger_state, utf8 = position
          if utf8.zero? && accepts_at_eof?(subset, smaller_state) && !accepts_at_eof?(superset, larger_state)
            input = inclusion_input(position, parents).force_encoding(encoding)
            return Result.new(status: :different, input: input, offset: 0, left: nil, right: nil, reason: nil)
          end

          bytes.each do |byte|
            next_utf8 = utf8_rows.fetch(utf8).fetch(byte)
            next unless next_utf8

            next_smaller = subset.transition(smaller_state, byte)
            next unless next_smaller

            next_larger = larger_state && superset.transition(larger_state, byte)
            target = [next_smaller, next_larger, next_utf8]
            next if parents.key?(target)
            raise SearchLimit if parents.length >= limit

            parents[target] = [position, byte]
            queue << target
          end
        end
        Result.new(status: :equal, input: nil, offset: nil, left: nil, right: nil, reason: nil)
      rescue SearchLimit
        Result.new(status: :inconclusive, input: nil, offset: nil, left: nil, right: nil, reason: "search limit reached")
      end

      def accepts_at_eof?(dfa, state)
        state && dfa.accepts.fetch(state).any? { |label| label.valid_end?(nil) }
      end

      def inclusion_input(position, parents)
        bytes = []
        while (entry = parents.fetch(position))
          position, byte = entry
          bytes << byte
        end
        bytes.reverse.pack("C*")
      end

      private_class_method :accepts_at_eof?, :inclusion_input
    end
  end
end
