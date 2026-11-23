# frozen_string_literal: true

module Flexr
  module Automaton
    class DerivativeTerms
      FAIL = 0
      EMPTY = 1

      attr_reader :byte_classes, :expressions, :operations

      def initialize
        @byte_classes = ByteClassSet.new
        @expressions = []
        @operations = []
        @ids = {}
        @nullable = []
        @derivatives = []
        @graphs = []
        @graph_ids = {}.compare_by_identity
        intern(:fail, [], false)
        intern(:empty, [], true)
        @universe = negate(FAIL)
      end

      def from_ast(node)
        case node
        when Regexp::AST::Empty then EMPTY
        when Regexp::AST::Fail then FAIL
        when Regexp::AST::ByteRange
          @byte_classes.add_range(node.lo, node.hi)
          intern(:byte, [node.lo, node.hi], false)
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
        when Regexp::AST::ByteAutomaton then from_graph(node.fragment)
        else raise CompileError, "cannot derive #{node.class}"
        end
      end

      def nullable?(id)
        @nullable.fetch(id)
      end

      def derivative(id, byte, class_id)
        (@derivatives[id] ||= [])[class_id] ||= derive(id, byte, class_id)
      end

      private

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

        intern(:sequence, parts, parts.all? { |id| nullable?(id) })
      end

      def union(ids)
        combine(:union, ids, identity: FAIL, absorbing: @universe)
      end

      def intersection(ids)
        combine(:intersection, ids, identity: @universe, absorbing: FAIL)
      end

      def combine(kind, ids, identity:, absorbing:)
        parts = flattened(kind, ids)
        return absorbing if parts.include?(absorbing)

        parts.delete(identity)
        parts = parts.uniq.sort
        return identity if parts.empty?
        return parts.first if parts.one?

        nullable = kind == :union ? parts.any? { |id| nullable?(id) } : parts.all? { |id| nullable?(id) }
        intern(kind, parts, nullable)
      end

      def negate(id)
        term = @expressions.fetch(id)
        return term.fetch(1) if term.first == :negate

        intern(:negate, [id], !nullable?(id))
      end

      def repeat(id, minimum, maximum)
        return EMPTY if id == EMPTY || maximum&.zero?
        return minimum.zero? ? EMPTY : FAIL if id == FAIL

        minimum = 0 if nullable?(id)
        return id if minimum == 1 && maximum == 1

        intern(:repeat, [id, minimum, maximum], minimum.zero?)
      end

      def derive(id, byte, class_id)
        kind, *parts = @expressions.fetch(id)
        case kind
        when :empty, :fail then FAIL
        when :byte then byte.between?(*parts) ? EMPTY : FAIL
        when :sequence then derive_sequence(parts, byte, class_id)
        when :union then union(parts.map { |part| derivative(part, byte, class_id) })
        when :intersection then intersection(parts.map { |part| derivative(part, byte, class_id) })
        when :negate then negate(derivative(parts.first, byte, class_id))
        when :repeat
          part, minimum, maximum = parts
          head = derivative(part, byte, class_id)
          return FAIL if head == FAIL

          sequence([head, repeat(part, [minimum - 1, 0].max, maximum && (maximum - 1))])
        when :graph
          graph_id, state = parts
          target = @graphs.fetch(graph_id).transition(state, byte)
          target ? graph_term(graph_id, target) : FAIL
        end
      end

      def derive_sequence(parts, byte, class_id)
        choices = []
        parts.each_with_index do |part, index|
          head = derivative(part, byte, class_id)
          choices << sequence([head, *parts.drop(index + 1)]) unless head == FAIL
          break unless nullable?(part)
        end
        union(choices)
      end

      def from_graph(input)
        id = @graph_ids[input] ||= begin
          dfa = input.is_a?(DFA) ? input : fragment_dfa(input)
          dfa.ec.each_index.chunk { |byte| dfa.ec.fetch(byte) }.each do |_, bytes|
            @byte_classes.add_range(bytes.first, bytes.last)
          end
          @graphs.push(dfa).length - 1
        end
        graph_term(id, @graphs.fetch(id).start)
      end

      def graph_term(id, state)
        nullable = !@graphs.fetch(id).accepts.fetch(state).empty?
        intern(:graph, [id, state], nullable)
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
