# frozen_string_literal: true

module Flexr
  module Automaton
    NFAState = Struct.new(:epsilon, :transitions, :accepts, keyword_init: true)
    NFATransition = Struct.new(:lo, :hi, :to, keyword_init: true)

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
        when Regexp::AST::Fail
          [@nfa.new_state, @nfa.new_state]
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
          repeat_fragment(node.child, 0, nil)
        when Regexp::AST::Repeat
          repeat_fragment(node.child, node.minimum, node.maximum)
        else
          raise CompileError, "cannot build NFA from #{node.class}"
        end
      end

      def repeat_fragment(child, minimum, maximum)
        return fragment(Regexp::AST::Empty.new(loc: nil)) if maximum&.zero?
        return star_fragment(child) if minimum.zero? && maximum.nil?

        from = @nfa.new_state
        cursor = from
        last_start = nil
        minimum.times do
          child_start, child_end = fragment(child)
          @nfa.epsilon(cursor, child_start)
          cursor = child_end
          last_start = child_start
        end
        if maximum.nil?
          @nfa.epsilon(cursor, last_start)
          return [from, cursor]
        end

        (maximum - minimum).times do
          child_start, child_end = fragment(child)
          next_cursor = @nfa.new_state
          @nfa.epsilon(cursor, next_cursor)
          @nfa.epsilon(cursor, child_start)
          @nfa.epsilon(child_end, next_cursor)
          cursor = next_cursor
        end
        [from, cursor]
      end

      def star_fragment(child)
        from = @nfa.new_state
        to = @nfa.new_state
        child_start, child_end = fragment(child)
        @nfa.epsilon(from, to)
        @nfa.epsilon(from, child_start)
        @nfa.epsilon(child_end, child_start)
        @nfa.epsilon(child_end, to)
        [from, to]
      end
    end
  end
end
