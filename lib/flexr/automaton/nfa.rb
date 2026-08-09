# frozen_string_literal: true

module Flexr
  module Automaton
    NFAState = Struct.new(:epsilon, :transitions, :accepts, keyword_init: true)
    NFATransition = Struct.new(:lo, :hi, :to, keyword_init: true)
    Acceptance = Struct.new(:rule_index, :pattern_index, :bol_only, :end_anchor, keyword_init: true) do
      def inspect
        [rule_index, pattern_index, bol_only, end_anchor].inspect
      end
    end

    class NFA
      attr_reader :states, :start, :byte_classes

      def initialize
        @states = []
        @start = new_state
        @byte_classes = ByteClassSet.new
      end

      def new_state
        id = @states.length
        @states << NFAState.new(epsilon: [], transitions: [], accepts: [])
        id
      end

      def epsilon(from, to)
        @states[from].epsilon << to
      end

      def transition(from, lo, hi, to)
        @states[from].transitions << NFATransition.new(lo: lo, hi: hi, to: to)
        @byte_classes.add_range(lo, hi)
      end
    end

    class NFABuilder
      def initialize
        @nfa = NFA.new
      end

      def build(patterns)
        patterns.each do |pattern, acceptance|
          start, finish = fragment(pattern)
          @nfa.epsilon(@nfa.start, start)
          @nfa.states[finish].accepts << acceptance
        end
        @nfa
      end

      private

      def fragment(node)
        case node
        when Regexp::AST::Empty
          state = @nfa.new_state
          [state, state]
        when Regexp::AST::ByteRange
          from = @nfa.new_state
          to = @nfa.new_state
          @nfa.transition(from, node.lo, node.hi, to)
          [from, to]
        when Regexp::AST::Seq
          fragments = node.children.map { |child| fragment(child) }
          fragments.each_cons(2) { |(_, end_state), (start_state, _)| @nfa.epsilon(end_state, start_state) }
          [fragments.first.first, fragments.last.last]
        when Regexp::AST::Alt
          from = @nfa.new_state
          to = @nfa.new_state
          node.children.each do |child|
            child_start, child_end = fragment(child)
            @nfa.epsilon(from, child_start)
            @nfa.epsilon(child_end, to)
          end
          [from, to]
        when Regexp::AST::Star
          from = @nfa.new_state
          to = @nfa.new_state
          child_start, child_end = fragment(node.child)
          @nfa.epsilon(from, to)
          @nfa.epsilon(from, child_start)
          @nfa.epsilon(child_end, child_start)
          @nfa.epsilon(child_end, to)
          [from, to]
        else
          raise CompileError, "cannot build NFA from #{node.class}"
        end
      end
    end
  end
end
