# frozen_string_literal: true

module Flexr
  module Automaton
    class ContextualRegexpCompiler
      def initialize(&state_limit)
        @instructions = []
        @state_limit = state_limit
        @accept = append(:accept)
      end

      def compile(ast, regexp, replay: nil, **)
        @replay = replay
        entry = build(ast, @accept)
        Runtime::ContextualRegexp.new(regexp: regexp, instructions: @instructions, entry: entry, replay: replay, **)
      end

      def lookbehind_width(node)
        case node
        when Regexp::AST::WordBoundary then 4
        when Regexp::AST::Lookbehind
          consuming_width(node.child) + lookbehind_width(node.child)
        when Regexp::AST::Seq, Regexp::AST::Alt
          node.children.map { |child| lookbehind_width(child) }.max || 0
        when Regexp::AST::Difference, Regexp::AST::Intersection
          [lookbehind_width(node.left), lookbehind_width(node.right)].max
        when Regexp::AST::Star, Regexp::AST::Repeat, Regexp::AST::NamedCapture, Regexp::AST::Lookahead
          lookbehind_width(node.child)
        else 0
        end
      end

      private

      def consuming_width(node)
        case node
        when Regexp::AST::ByteRange then 1
        when Regexp::AST::Seq then node.children.sum { |child| consuming_width(child) }
        when Regexp::AST::Alt then node.children.map { |child| consuming_width(child) }.max
        when Regexp::AST::NamedCapture then consuming_width(node.child)
        when Regexp::AST::Repeat then (node.maximum || node.minimum) * consuming_width(node.child)
        else 0
        end
      end

      def append(*instruction)
        @state_limit.call(@instructions.length)
        @instructions.push(instruction).length - 1
      end

      def build(node, following)
        case node
        when Regexp::AST::Empty then following
        when Regexp::AST::Anchor
          return following if node.kind == :bol
          return append(:line_end, following) if @replay == :ruby && node.kind == :eol
          return append(:left_anchor, node.kind, following) if Regexp::AST.left_anchor?(node)

          predicate(node, following)
        when Regexp::AST::Fail then nil
        when Regexp::AST::ByteRange then append(:byte, node.lo, node.hi, following)
        when Regexp::AST::NotNextLineFeed then append(:not_lf, following)
        when Regexp::AST::Seq then node.children.reverse_each.reduce(following) { |tail, part| build(part, tail) }
        when Regexp::AST::Alt
          node.children.reverse_each.reduce(nil) { |tail, part| choice(build(part, following), tail) }
        when Regexp::AST::NamedCapture then build(node.child, following)
        when Regexp::AST::Lookahead then assertion(node, following)
        when Regexp::AST::Lookbehind, Regexp::AST::WordBoundary then predicate(node, following)
        when Regexp::AST::Grapheme then append(:span, node.dfa, following)
        when Regexp::AST::Difference, Regexp::AST::Intersection then append(:span, language(node), following)
        when Regexp::AST::Star then repeated(node.child, 0, nil, following)
        when Regexp::AST::Repeat then repeated(node.child, node.minimum, node.maximum, following)
        else raise CompileError, "cannot resolve context for #{node.class}"
        end
      end

      def assertion(node, following)
        return append(:lookahead, build(node.child, @accept), following) if !node.negative && Regexp::AST.named_capture?(node.child)

        predicate(node, following)
      end

      def predicate(node, following)
        dfa = language(node)
        if dfa.starts
          choices = dfa.starts.map { |state| dfa.accepts.fetch(state).first }.freeze
          return append(:context_predicate, choices, following, dfa.left_context) if dfa.left_context

          return append(:context_predicate, choices, following)
        end

        acceptance = dfa.accepts.fetch(dfa.start).first
        return unless acceptance
        return following unless acceptance.end_anchor

        append(:predicate, acceptance, following)
      end

      def language(node)
        require_relative "derivative_compiler"

        accept = Acceptance.new(rule_index: 0, pattern_index: 0)
        DerivativeCompiler.new.compile([[node, accept]]) { |states, _| @state_limit.call(states) }
      end

      def choice(first, second)
        return second unless first
        return first unless second

        append(:choice, first, second)
      end

      def repeated(child, minimum, maximum, following)
        tail = if maximum
          (maximum - minimum).times.reduce(following) { |next_iteration, _| choice(build(child, next_iteration), following) }
        else
          loop_head = append(:loop, nil, following)
          loop_end = append(:loop_end, loop_head, following)
          @instructions.fetch(loop_head)[1] = build(child, loop_end)
          loop_head
        end
        minimum.times.reduce(tail) { |next_iteration, _| build(child, next_iteration) }
      end
    end
  end
end
