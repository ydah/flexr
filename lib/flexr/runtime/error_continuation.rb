# frozen_string_literal: true

module Flexr
  module Runtime
    class ErrorContinuation
      MAX_STATES = 8_192
      MAX_WORK = 500_000
      class WorkLimit < StandardError; end

      Position = Data.define(:encoding, :branch, :consumed)
      Body = Data.define(:state, :history, :bol, :keyword, :bracket)
      Trailer = Data.define(:dfa, :state, :bol, :guard)
      End = Data.define(:guards)
      Guard = Data.define(:label_id, :state)
      Edge = Data.define(:bytes, :targets)
      private_constant :WorkLimit, :Position, :Body, :Trailer, :End, :Guard, :Edge

      def self.find(lexer, expected)
        new(lexer, expected).find
      rescue WorkLimit, CompileError
        nil
      end

      def initialize(lexer, expected)
        @lexer = lexer
        @buffer = lexer.buffer
        @start = lexer.byte_pos
        @bol = lexer.beginning_of_line?
        @config = lexer.class.__flexr_config
        @dfa = lexer.class.__flexr_compiled.machines.fetch(lexer.state).dfa
        @rules = lexer.class.__flexr_rules
        @expected = expected
        @work = MAX_WORK
        @guard_labels = []
        @guard_ids = {}.compare_by_identity
      end

      def find
        @encoding = Automaton::UTF8.rows(@config.encoding)
        return unless @encoding

        prepare_trailers
        prepare_expectations
        position = start_position
        prefix, cursor = replay(expand(position))
        eof = cursor == @buffer.bytesize
        return if eof && !@buffer.eof_loaded?

        edges, distances = accepting_paths(prefix)
        next_bytes = viable_bytes(prefix, edges, distances)
        suffix = shortest_suffix(prefix, edges, distances)
        LexError::Continuation.new(byte_pos: cursor, expected_bytes: next_bytes, suffix: suffix, eof: eof)
      end

      private

      def prepare_trailers
        compiled = {}
        @trailers = @dfa.rule_ids.to_h do |index|
          rule = @rules.fetch(index)
          trail = rule.trailing_dfa
          if rule.trailing && !trail
            raise WorkLimit unless Flexr.respond_to?(:compile_pattern)

            trail = compiled[rule.trailing] ||= Flexr.compile_pattern(
              rule.trailing, encoding: @config.encoding, options: { unicode: @config.options[:unicode] == true }
            )
          end
          [index, trail]
        end
        @left_graphs = @trailers.values.compact.filter_map(&:left_context).uniq(&:object_id)
        @left_indices = {}.compare_by_identity
        @left_graphs.each_with_index { |graph, index| @left_indices[graph] = index }
      end

      def prepare_expectations
        @keywords = @expected && @config.options[:keyword_tables]
        @keyword_rows, @keyword_labels = trie(@keywords&.values&.flat_map(&:keys) || [])
        indentation = @expected && @config.options[:indentation]
        # An empty lexeme can trigger indentation but cannot match a bracket.
        @layout_expected = indentation &&
          @lexer.__flexr_layout_candidate?(@expected, @start, @lexer.more_text_start || @start)
        brackets = indentation&.fetch(:brackets)&.flat_map(&:chars)
        @bracket_rows, @bracket_labels = trie(brackets || [])
        @distinguished_bytes = (@keyword_rows + @bracket_rows).flat_map(&:keys).to_h { |byte| [byte, true] }
      end

      def trie(texts)
        rows = [{}]
        labels = {}
        texts.each do |text|
          state = 0
          text.each_byte do |byte|
            state = rows.fetch(state)[byte] ||= rows.length.tap { rows << {} }
          end
          labels[state] = text
        end
        [rows, labels]
      end

      def start_position
        history = @left_graphs.map { |graph| @buffer.left_state_at(graph, @start) }
        bracket = 0
        if !@bracket_labels.empty? && (starting = @lexer.more_text_start) && starting < @start
          previous = @buffer.byteslice(starting...@start)
          bracket = previous.each_byte.reduce(bracket) { |state, byte| trie_step(@bracket_rows, state, byte) }
        end
        branch = Body.new(state: @lexer.__flexr_dfa_start(@dfa, @start), history: history,
                          bol: @bol, keyword: 0, bracket: bracket)
        Position.new(encoding: 0, branch: branch, consumed: false)
      end

      def replay(states)
        cursor = @start
        limit = @buffer.bytesize
        while cursor < limit
          byte = @buffer.getbyte(cursor)
          following = states.flat_map { |state| advance(state, byte) }.uniq
          break if following.empty?

          states = following
          cursor += 1
        end
        [states, cursor]
      end

      def expand(position)
        return [position] unless position.encoding.zero?

        branch = position.branch
        alternatives = case branch
        when Body then body_ends(position, branch)
        when Trailer then [trailer_end(branch)].compact
        else []
        end
        [position, *alternatives.map { |alternative| position.with(branch: alternative) }]
      end

      def body_ends(position, body)
        return [] unless position.consumed || @config.options[:allow_empty_match]

        @dfa.accepts.fetch(body.state).flat_map do |label|
          charge
          rule = @rules.fetch(label.rule_index)
          next [] if (label.bol_only && !@bol) || !expected_rule?(rule, body)

          guard = start_guard(label)
          next [] if guard == false

          trailer = @trailers.fetch(rule.index)
          next [End.new(guards: [guard].compact)] unless trailer

          state = trailer_start(trailer, position, body)
          tail = Trailer.new(dfa: trailer, state: state, bol: body.bol, guard: guard)
          [tail, trailer_end(tail)].compact
        end
      end

      def trailer_start(dfa, position, body)
        return dfa.start unless dfa.starts

        context = if dfa.left_context
          body.history.fetch(@left_indices.fetch(dfa.left_context))
        elsif !position.consumed && @start.zero?
          Automaton::LeftContext::SOURCE_START
        else
          body.bol ? Automaton::LeftContext::AFTER_LF : Automaton::LeftContext::OTHER
        end
        dfa.start_for(context)
      end

      def trailer_end(trailer)
        label = trailer.dfa.accepts.fetch(trailer.state).first
        return unless label && (trailer.bol || !label.bol_only)

        guard = start_guard(label)
        return if guard == false

        End.new(guards: [trailer.guard, guard].compact)
      end

      def expected_rule?(rule, body)
        return true unless @expected
        return true if rule.skip? || rule.channel || @layout_expected || @bracket_labels.key?(body.bracket)
        return rule.emits.any? { |type| @expected.key?(type) } if rule.emits
        return true unless rule.emit?

        type = rule.action[1]
        type = @keywords&.dig(type, @keyword_labels[body.keyword])&.first || type
        @expected.key?(type)
      end

      def start_guard(label)
        predicate = label.end_anchor
        return unless predicate

        id = @guard_ids[predicate] ||= @guard_labels.length.tap { @guard_labels << label }
        return Guard.new(label_id: id, state: nil) unless lookahead?(predicate)

        guard_after_state(id, predicate, 0)
      end

      def guard_after_state(id, predicate, state)
        row = predicate.transitions.fetch(state)
        return Guard.new(label_id: id, state: state) if row.is_a?(Array)

        false unless row
      end

      def lookahead?(predicate)
        defined?(Automaton::Lookahead) && predicate.is_a?(Automaton::Lookahead)
      end

      def advance_guard(guard, byte)
        return unless guard

        label = @guard_labels.fetch(guard.label_id)
        return (false unless label.valid_end?(byte)) unless guard.state

        predicate = label.end_anchor
        target = predicate.transitions.fetch(guard.state).fetch(predicate.ec.fetch(byte))
        guard_after_state(guard.label_id, predicate, target)
      end

      def accepts_eof?(position)
        return false unless position.consumed && position.encoding.zero? && position.branch.is_a?(End)

        position.branch.guards.all? do |guard|
          label = @guard_labels.fetch(guard.label_id)
          guard.state ? label.end_anchor.eof.fetch(guard.state) : label.valid_end?(nil)
        end
      end

      def advance(position, byte)
        charge
        encoding = @encoding.fetch(position.encoding).fetch(byte)
        return [] unless encoding

        branch = case position.branch
        when Body then advance_body(position.branch, byte)
        when Trailer then advance_trailer(position.branch, byte)
        when End then advance_end(position.branch, byte)
        end
        branch ? expand(Position.new(encoding: encoding, branch: branch, consumed: true)) : []
      end

      def advance_body(body, byte)
        target = @dfa.transition(body.state, byte)
        return unless target

        charge(@left_graphs.length)
        history = @left_graphs.each_with_index.map { |graph, index| graph.transition(body.history.fetch(index), byte) }
        Body.new(state: target, history: history, bol: byte == 0x0a,
                 keyword: trie_step(@keyword_rows, body.keyword, byte), bracket: trie_step(@bracket_rows, body.bracket, byte))
      end

      def trie_step(rows, state, byte)
        rows.fetch(state)[byte] if state
      end

      def advance_trailer(trailer, byte)
        target = trailer.dfa.transition(trailer.state, byte)
        return unless target

        guard = advance_guard(trailer.guard, byte)
        trailer.with(state: target, guard: guard) unless guard == false
      end

      def advance_end(ending, byte)
        guards = ending.guards.map { |guard| advance_guard(guard, byte) }
        End.new(guards: guards.compact) unless guards.include?(false)
      end

      def alphabet
        dfas = [@dfa, *@trailers.values.compact].uniq(&:object_id)
        predicates = dfas.flat_map do |dfa|
          dfa.accepts.flat_map do |labels|
            charge(labels.length)
            labels.filter_map { |label| label.end_anchor if lookahead?(label.end_anchor) }
          end
        end
        classes = (dfas + predicates + @left_graphs).uniq(&:object_id).map(&:ec).uniq + @encoding
        charge(256 * classes.length)
        256.times.group_by do |byte|
          [byte == 0x0a, (byte if @distinguished_bytes.key?(byte)), *classes.map { |row| row.fetch(byte) }]
        end.values
      end

      def accepting_paths(prefix)
        bytes = alphabet
        pending = prefix.dup
        seen = prefix.to_h { |state| [state, true] }
        parents = Hash.new { |nodes, state| nodes[state] = [] }
        edges = {}
        accepting = []
        pending.each do |state|
          accepting << state if accepts_eof?(state)
          edges[state] = bytes.filter_map do |byte_class|
            targets = advance(state, byte_class.first).uniq
            next if targets.empty?

            targets.each do |target|
              parents[target] << state
              next if seen[target]

              raise WorkLimit if pending.length >= MAX_STATES

              pending << target
              seen[target] = true
            end
            Edge.new(bytes: byte_class, targets: targets)
          end
        end
        # A live edge may still lead to an impossible contextual match.
        distances = accepting.to_h { |state| [state, 0] }
        accepting.each do |state|
          parents.fetch(state, []).each do |parent|
            next if distances.key?(parent)

            distances[parent] = distances.fetch(state) + 1
            accepting << parent
          end
        end
        [edges, distances]
      end

      def viable_bytes(prefix, edges, distances)
        bytes = prefix.flat_map do |state|
          edges.fetch(state).select { |edge| edge.targets.any? { |target| distances.key?(target) } }.flat_map(&:bytes)
        end
        bytes.sort.uniq.slice_when { |before, after| before + 1 != after }.map do |range|
          range.first..range.last
        end.freeze
      end

      def shortest_suffix(prefix, edges, distances)
        state = prefix.select { |node| distances.key?(node) }.min_by { |node| distances.fetch(node) }
        return unless state

        distance = distances.fetch(state)
        suffix = String.new(encoding: Encoding::BINARY)
        while distance.positive?
          distance -= 1
          edge = edges.fetch(state).find { |candidate| candidate.targets.any? { |target| distances[target] == distance } }
          suffix << edge.bytes.first
          state = edge.targets.find { |target| distances[target] == distance }
        end
        utf8 = suffix.dup.force_encoding(Encoding::UTF_8) if @config.encoding == Encoding::UTF_8
        (utf8&.valid_encoding? ? utf8 : suffix).freeze
      end

      def charge(amount = 1)
        @work -= amount
        raise WorkLimit if @work.negative?
      end
    end
    private_constant :ErrorContinuation
  end
end
