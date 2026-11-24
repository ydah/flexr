# frozen_string_literal: true

module Flexr
  module Automaton
    class DerivativeTerms
      FAIL = 0
      EMPTY = 1
      UNIVERSE = 2

      attr_reader :byte_classes, :expressions, :operations

      def advance(vector, byte, class_id)
        vector.each_with_object({}) do |(pattern, term), residuals|
          residual = derivative(term, byte, class_id)
          residuals[pattern] = residual unless residual == FAIL
        end.freeze
      end

      def initialize
        @byte_classes = ByteClassSet.new
        @expressions = []
        @operations = []
        @ids = {}
        @nullable = []
        @derivatives = []
        @graphs = []
        @graph_ids = {}.compare_by_identity
        intern(:fail, [], FAIL)
        intern(:empty, [], UNIVERSE)
        intern(:negate, [FAIL], UNIVERSE)
        @lookaheads = {}
        @suffix_graphs = []
        @suffix_graph_ids = {}.compare_by_identity
      end

      def from_ast(node)
        case node
        when Regexp::AST::Empty then EMPTY
        when Regexp::AST::Fail then FAIL
        when Regexp::AST::NotNextLineFeed
          guard(end_conditions.fetch(EndContext::EOF | EndContext::OTHER), EMPTY)
        when Regexp::AST::NamedCapture then from_ast(node.child)
        when Regexp::AST::Lookahead
          @explicit_lookahead = true
          end_conditions
          predicate = prefix(from_ast(node.child))
          guard(node.negative ? negate(predicate) : predicate, EMPTY)
        when Regexp::AST::ByteRange
          @byte_classes.add_range(node.lo, node.hi)
          intern(:byte, [node.lo, node.hi], FAIL)
        when Regexp::AST::Seq then sequence(node.children.map { |child| from_ast(child) })
        when Regexp::AST::Alt then union(node.children.map { |child| from_ast(child) })
        when Regexp::AST::Star then repeat(from_ast(node.child), 0, nil)
        when Regexp::AST::Repeat then repeat(from_ast(node.child), node.minimum, node.maximum)
        when Regexp::AST::Difference
          operation = node.operation || "absence group"
          @operations << operation unless @operations.include?(operation)
          intersection([from_ast(node.left), negate(from_ast(node.right))])
        when Regexp::AST::Intersection then intersection([from_ast(node.left), from_ast(node.right)])
        when Regexp::AST::EmbeddedDFA then from_graph(node.dfa)
        when Regexp::AST::FirstEnding then first_ending(from_ast(node.child))
        when Regexp::AST::ByteAutomaton then from_graph(node.fragment)
        else raise CompileError, "cannot derive #{node.class}"
        end
      end

      def accepting_conditions(vector, conditions, ec:, representatives:, &state_limit)
        vector.filter_map do |pattern, term|
          nullable = nullability(term)
          next if nullable == FAIL

          entry = conditions.fetch(pattern)
          next entry if nullable == UNIVERSE

          required = predicate_for(entry.end_anchor)
          allowed = intersection([nullable, required])
          next if allowed == FAIL
          next entry if allowed == required

          condition = if !@explicit_lookahead && (mask = @masks_by_predicate[allowed])
            EndContext.condition(mask)
          else
            lookahead = @lookaheads.fetch(allowed) do
              @lookaheads[allowed] = build_lookahead(allowed, ec, representatives, &state_limit)
            end
            next unless lookahead

            lookahead
          end
          entry.dup.tap { |copy| copy.end_anchor = condition }
        end.uniq
      end

      def context_dependent_end?
        @explicit_lookahead || @graphs.any?(&:context_dependent_end?) ||
          @nullable.any? { |mask| !mask.zero? && EndContext.condition(mask).is_a?(Integer) }
      end

      def derivative(id, byte, class_id)
        (@derivatives[id] ||= [])[class_id] ||= derive(id, byte, class_id)
      end

      private

      def nullability(id)
        @nullable.fetch(id)
      end

      def term(kind, parts)
        @ids[[kind, *parts]] || intern(kind, parts, yield)
      end

      def guard(predicate, body)
        return FAIL if predicate == FAIL || body == FAIL
        return body if predicate == UNIVERSE

        kind, nested, tail = @expressions.fetch(body)
        return guard(intersection([predicate, nested]), tail) if kind == :guard

        term(:guard, [predicate, body]) { intersection([predicate, nullability(body)]) }
      end

      # A lookahead accepts an input suffix if its body can match any prefix,
      # including an empty one when that body's own assertions hold.
      def prefix(body)
        return FAIL if body == FAIL
        return UNIVERSE if nullability(body) == UNIVERSE

        term(:prefix, [body]) { nullability(nullability(body)) }
      end

      def first_ending(term)
        return term if [FAIL, EMPTY].include?(term)

        intern(:first_ending, [term], nullability(term))
      end

      def predicate_for(condition)
        return UNIVERSE unless condition
        if condition.is_a?(Lookahead)
          id = @suffix_graph_ids[condition] ||= begin
            condition.ec.each_index.chunk { |byte| condition.ec.fetch(byte) }.each do |_, bytes|
              @byte_classes.add_range(bytes.first, bytes.last)
            end
            @suffix_graphs.push(condition).length - 1
          end
          return suffix_term(id, 0)
        end

        end_conditions.fetch(EndContext.mask(condition))
      end

      def suffix_term(id, state)
        graph = @suffix_graphs.fetch(id)
        row = graph.transitions.fetch(state)
        return UNIVERSE if row == true
        return FAIL if row == false

        intern(:suffix_graph, [id, state], graph.eof.fetch(state) ? UNIVERSE : FAIL)
      end

      def end_conditions
        @end_conditions ||= begin
          @byte_classes.add_range(0x0a, 0x0a)
          lf = prefix(intern(:byte, [0x0a, 0x0a], FAIL))
          eol = union([EMPTY, lf])
          conditions = {
            0 => FAIL,
            EndContext::EOF => EMPTY,
            EndContext::LF => lf,
            EndContext::OTHER => negate(eol),
            EndContext::EOL => eol,
            (EndContext::EOF | EndContext::OTHER) => negate(lf),
            (EndContext::LF | EndContext::OTHER) => negate(EMPTY),
            EndContext::ANY => UNIVERSE
          }
          @masks_by_predicate = conditions.invert
          conditions
        end
      end

      def build_lookahead(start, ec, representatives)
        ids = { start => 0 }
        states = [start]
        transitions = []
        eof = []
        index = 0
        while index < states.length
          term = states.fetch(index)
          row = if [FAIL, UNIVERSE].include?(term)
            term == UNIVERSE
          else
            representatives.each_with_index.map do |byte, class_id|
              target = derivative(term, byte, class_id)
              ids[target] ||= begin
                yield states.length, "lookahead"
                states.push(target).length - 1
              end
            end.freeze
          end
          transitions << row
          eof << (nullability(term) == UNIVERSE)
          index += 1
        end
        Lookahead.new(transitions: transitions, eof: eof, ec: ec) if eof.any?
      end

      def intern(kind, arguments, nullable)
        key = [kind, *arguments].freeze
        @ids[key] ||= begin
          id = @expressions.length
          @expressions << key
          @nullable << nullable
          id
        end
      end

      def flattened(kind, ids)
        ids.flat_map do |id|
          term = @expressions.fetch(id)
          term.first == kind ? term.drop(1) : [id]
        end
      end

      def sequence(ids)
        parts = flattened(:sequence, ids)
        return FAIL if parts.include?(FAIL)

        parts.delete(EMPTY)
        return EMPTY if parts.empty?
        return parts.first if parts.one?

        term(:sequence, parts) { intersection(parts.map { |id| nullability(id) }) }
      end

      def union(ids)
        combine(:union, ids, identity: FAIL, absorbing: UNIVERSE)
      end

      def intersection(ids)
        combine(:intersection, ids, identity: UNIVERSE, absorbing: FAIL)
      end

      def combine(kind, ids, identity:, absorbing:)
        parts = flattened(kind, ids)
        return absorbing if parts.include?(absorbing)

        parts.delete(identity)
        parts = parts.uniq.sort
        return identity if parts.empty?
        return parts.first if parts.one?

        term(kind, parts) do
          predicates = parts.map { |id| nullability(id) }
          kind == :union ? union(predicates) : intersection(predicates)
        end
      end

      def negate(id)
        term = @expressions.fetch(id)
        return term.fetch(1) if term.first == :negate

        term(:negate, [id]) { negate(nullability(id)) }
      end

      def repeat(id, minimum, maximum)
        return EMPTY if id == EMPTY || maximum&.zero?
        return minimum.zero? ? EMPTY : FAIL if id == FAIL

        nullable = nullability(id)
        minimum = 0 if nullable == UNIVERSE
        return id if minimum == 1 && maximum == 1

        intern(:repeat, [id, minimum, maximum], minimum.zero? ? UNIVERSE : nullable)
      end

      def derive(id, byte, class_id)
        kind, *parts = @expressions.fetch(id)
        case kind
        when :empty, :fail then FAIL
        when :guard
          predicate, body = parts
          guard(derivative(predicate, byte, class_id), derivative(body, byte, class_id))
        when :first_ending
          body = parts.first
          before_ending = derivative(negate(nullability(body)), byte, class_id)
          guard(before_ending, first_ending(derivative(body, byte, class_id)))
        when :prefix
          body = parts.first
          union([derivative(nullability(body), byte, class_id), prefix(derivative(body, byte, class_id))])
        when :byte then byte.between?(*parts) ? EMPTY : FAIL
        when :sequence then derive_sequence(parts, byte, class_id)
        when :union then union(parts.map { |part| derivative(part, byte, class_id) })
        when :intersection then intersection(parts.map { |part| derivative(part, byte, class_id) })
        when :negate then negate(derivative(parts.first, byte, class_id))
        when :repeat
          part, minimum, maximum = parts
          head = derivative(part, byte, class_id)
          return FAIL if head == FAIL

          remaining = [minimum - 1, 0].max
          maximum -= 1 if maximum
          consumed = sequence([head, repeat(part, remaining, maximum)])
          return consumed if remaining.zero? || nullability(part) == FAIL

          skipped = derivative(nullability(part), byte, class_id)
          union([consumed, guard(skipped, sequence([head, repeat(part, 0, maximum)]))])
        when :suffix_graph
          graph, state = parts
          input = @suffix_graphs.fetch(graph)
          row = input.transitions.fetch(state)
          suffix_term(graph, row.fetch(input.ec.fetch(byte)))
        when :graph
          graph_id, state = parts
          target = @graphs.fetch(graph_id).transition(state, byte)
          target ? graph_term(graph_id, target) : FAIL
        end
      end

      def derive_sequence(parts, byte, class_id)
        choices = []
        condition = UNIVERSE
        parts.each_with_index do |part, index|
          head = derivative(part, byte, class_id)
          choices << guard(condition, sequence([head, *parts.drop(index + 1)])) unless head == FAIL
          nullable = nullability(part)
          break if nullable == FAIL

          condition = intersection([condition, derivative(nullable, byte, class_id)]) unless nullable == UNIVERSE
          break if condition == FAIL
        end
        union(choices)
      end

      def from_graph(input)
        id = @graph_ids[input] ||= begin
          dfa = input.is_a?(DFA) ? input : fragment_dfa(input)
          dfa.ec.each_index.chunk { |byte| dfa.ec.fetch(byte) }.each do |_, bytes|
            @byte_classes.add_range(bytes.first, bytes.last)
          end
          if dfa.context_dependent_end?
            @explicit_lookahead ||= dfa.lookahead?
            end_conditions
          end
          @graphs.push(dfa).length - 1
        end
        graph_term(id, @graphs.fetch(id).start)
      end

      def graph_term(id, state)
        term(:graph, [id, state]) do
          labels = @graphs.fetch(id).accepts.fetch(state)
          union(labels.map { |label| predicate_for(label.end_anchor) })
        end
      end

      def fragment_dfa(fragment)
        classes = ByteClassSet.new
        fragment.edges.each_slice(4) { |_, lo, hi, _| classes.add_range(lo, hi) }
        ec, count = classes.build
        rows = Array.new(fragment.state_count) { Array.new(count) }
        fragment.edges.each_slice(4) do |from, lo, hi, to|
          rows.fetch(from).fill(to, ec.fetch(lo)..ec.fetch(hi))
        end
        accepts = Array.new(fragment.state_count) { [] }
        accepts[fragment.accept] = [Acceptance.new(rule_index: 0, pattern_index: 0)]
        DFA.new(transitions: rows, accepts: accepts, ec: ec, class_count: count, start: 0, rule_ids: [0])
      end
    end
  end
end
