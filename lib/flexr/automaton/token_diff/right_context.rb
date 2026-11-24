# frozen_string_literal: true

module Flexr
  module Automaton
    module TokenDiff
      class RightContext
        Signature = Data.define(:edge, :utf8, :guards, :prefixes)
        EMPTY = [].freeze
        private_constant :Signature, :EMPTY

        def initialize(labels, utf8_rows, track_edge: false, prefix_dfas: [])
          anchors = labels.filter_map(&:end_anchor)
          lookaheads = anchors.grep(Lookahead).uniq(&:object_id)
          @guards = lookaheads.uniq
          ids = @guards.each_with_index.to_h
          @guard_ids = {}.compare_by_identity
          lookaheads.each { |guard| @guard_ids[guard] = ids.fetch(guard) }
          @immediate = track_edge || anchors.any? { |anchor| !anchor.is_a?(Lookahead) }
          @utf8_rows = utf8_rows
          @prefix_ids = prefix_dfas.each_with_index.to_h
          @prefix_labels = prefix_dfas.map { |dfa| dfa.accepts.map(&:first) }
          @prefix_dfas = prefix_dfas
          eof = Signature.new(edge: EndContext::EOF, utf8: 1, guards: @guards.map { |guard| eof_mask(guard) }, prefixes: [])
          @signatures = [eof.with(prefixes: @prefix_labels.map { |labels| accepted_prefixes(labels, eof) })]
          @inverse = []
        end

        def byte_key(byte)
          [@immediate ? EndContext.for_byte(byte) : EndContext::EOF,
           @utf8_rows.map { |row| row.fetch(byte) }, @guards.map { |guard| guard.ec.fetch(byte) },
           @prefix_dfas.map { |dfa| dfa.ec.fetch(byte) }]
        end

        def initial
          @signatures.each_index.select { |index| @signatures.fetch(index).utf8.odd? }
        end

        def build(bytes, limit)
          symbols = bytes.map(&:last).uniq
          ids = { @signatures.first => 0 }
          @work = limit * 64
          build_predecessors(symbols)
          build_prefix_transitions(symbols)
          @signatures.each_with_index do |tail, id|
            symbols.each do |key|
              edge, utf8_classes, guard_classes, prefix_classes = key
              utf8 = utf8_predecessors(tail.utf8, utf8_classes)
              next if utf8.zero?

              masks = @guards.each_index.map do |index|
                always, incoming = @predecessors.fetch(index).fetch(guard_classes.fetch(index))
                charge(incoming.size)

                predecessor_mask(tail.guards.fetch(index), always, incoming)
              end
              current = Signature.new(edge: edge, utf8: utf8, guards: masks, prefixes: [])
              current = current.with(prefixes: prepend_prefixes(current, tail, prefix_classes)) unless @prefix_dfas.empty?
              head = ids[current] ||= begin
                raise SearchLimit if @signatures.length >= limit

                @signatures << current
                @signatures.length - 1
              end
              inverse = @inverse[head] ||= {}
              (inverse[key] ||= []) << id
            end
          end
        end

        def tails(right, byte_key)
          @inverse[right]&.fetch(byte_key, EMPTY) || EMPTY
        end

        def accepts?(condition, right)
          holds?(condition, @signatures.fetch(right))
        end

        def accepts_prefix?(dfa, state, bol, right)
          masks = @signatures.fetch(right).prefixes.fetch(@prefix_ids.fetch(dfa))
          masks.fetch(bol ? 1 : 0).anybits?(1 << state)
        end

        private

        def holds?(condition, signature)
          if condition.is_a?(Lookahead)
            signature.guards.fetch(@guard_ids.fetch(condition)).odd?
          else
            EndContext.mask(condition).anybits?(signature.edge)
          end
        end

        def build_predecessors(symbols)
          @predecessors = @guards.each_with_index.map do |guard, index|
            classes = symbols.map { |_, _, values| values.fetch(index) }.uniq
            classes.to_h do |byte_class|
              charge(guard.transitions.length)
              [byte_class, guard_predecessors(guard, byte_class)]
            end
          end
        end

        def build_prefix_transitions(symbols)
          @prefix_transitions = @prefix_dfas.each_with_index.map do |dfa, index|
            symbols.map { |key| key.last.fetch(index) }.uniq.to_h do |byte_class|
              charge(dfa.transitions.length)
              [byte_class, dfa.transitions.map { |row| row.fetch(byte_class) }]
            end
          end
        end

        def prepend_prefixes(signature, tail, classes)
          @prefix_labels.each_with_index.map do |labels, index|
            transitions = @prefix_transitions.fetch(index).fetch(classes.fetch(index))
            charge(labels.length + transitions.length)
            accepting = accepted_prefixes(labels, signature)
            # A trailing match ends here or starts with this byte and ends in the remaining suffix.
            accepting.zip(tail.prefixes.fetch(index)).map do |now, later|
              transitions.each_with_index.reduce(now) do |mask, (target, origin)|
                target && later[target] == 1 ? mask | (1 << origin) : mask
              end
            end
          end
        end

        def accepted_prefixes(labels, signature)
          return [0, 0] unless signature.utf8.odd?

          anywhere = at_bol = 0
          labels.each_with_index do |label, state|
            next unless label && holds?(label.end_anchor, signature)

            bit = 1 << state
            at_bol |= bit
            anywhere |= bit unless label.bol_only
          end
          [anywhere, at_bol]
        end

        def charge(work)
          @work -= work
          raise SearchLimit if @work.negative?
        end

        def guard_predecessors(guard, byte_class)
          always = 0
          incoming = Hash.new(0)
          guard.transitions.each_with_index do |row, origin|
            if row.is_a?(Array)
              incoming[1 << row.fetch(byte_class)] |= 1 << origin
            elsif row
              always |= 1 << origin
            end
          end
          [always, incoming]
        end

        def predecessor_mask(mask, always, incoming)
          incoming.reduce(always) do |bits, (target, origins)|
            mask.anybits?(target) ? bits | origins : bits
          end
        end

        def utf8_predecessors(mask, classes)
          classes.each_with_index.reduce(0) do |bits, (target, origin)|
            target && mask.anybits?(1 << target) ? bits | (1 << origin) : bits
          end
        end

        def eof_mask(guard)
          guard.eof.each_with_index.reduce(0) { |bits, (accepted, state)| accepted ? bits | (1 << state) : bits }
        end
      end
    end
  end
end
