# frozen_string_literal: true

module Flexr
  module Automaton
    CompiledSpec = Struct.new(:machines, :rules, :states, :stats, keyword_init: true)
    Machine = Struct.new(:dfa, :state_name, keyword_init: true)

    class Compiler
      def initialize(spec)
        @spec = spec
      end

      def compile
        validate_rules
        state_names = effective_states
        machines = state_names.to_h do |state_name|
          rules = rules_for(state_name)
          [state_name, Machine.new(dfa: compile_machine(rules), state_name: state_name)]
        end
        stats = machines.transform_values { |machine| machine.dfa.stats }
        CompiledSpec.new(machines: machines, rules: @spec.rules, states: state_names, stats: stats)
      end

      private

      def effective_states
        names = [:initial]
        @spec.states.each_key { |name| names << name unless names.include?(name) }
        names
      end

      def rules_for(state_name)
        state = @spec.states.fetch(state_name)
        @spec.rules.select do |rule|
          next true if state_name == :initial && rule.states.include?(:initial)
          next true if state.inclusive && rule.states.include?(:initial)
          next false unless rule.states.include?(state_name)

          !rule.states.empty?
        end
      end

      def compile_machine(rules)
        normalized = []
        rules.each do |rule|
          if reference_rule?(rule)
            validate_reference_patterns(rule)
            next
          end

          rule.patterns.each do |pattern|
            regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(::Regexp.escape(pattern.to_s))
            encoding = regexp.encoding == Encoding::BINARY ? Encoding::BINARY : @spec.encoding
            parser = Regexp::Parser.new(regexp.source, options: regexp.options, encoding: encoding,
                                        unicode: @spec.options[:unicode] == true)
            ast = parser.parse
            ast, bol_only, end_anchor = strip_anchors(ast)
            rule.bol_only = true if bol_only
            rule.end_anchor = true if end_anchor
            normalized_ast = Regexp::Normalizer.new(ast, encoding: encoding, options: regexp.options).normalize
            normalized << [normalized_ast, rule.index]
          end
        end
        return empty_dfa if normalized.empty?

        nfa = NFABuilder.new.build(normalized)
        ec, class_count = nfa.byte_classes.build
        subset_construction(nfa, ec, class_count)
      end

      def empty_dfa
        DFA.new(transitions: [[nil]], accepts: [[]], ec: Array.new(256, 0), class_count: 1, start: 0, rule_ids: [])
      end

      def reference_rule?(rule)
        rule.patterns.any? { |pattern| pattern.is_a?(::Regexp) && pattern.source.include?("\\p{") }
      end

      def validate_reference_patterns(rule)
        rule.patterns.each do |pattern|
          regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(::Regexp.escape(pattern.to_s))
          encoding = regexp.encoding == Encoding::BINARY ? Encoding::BINARY : @spec.encoding
          parser = Regexp::Parser.new(regexp.source, options: regexp.options, encoding: encoding,
                                      unicode: @spec.options[:unicode] == true)
          ast = parser.parse
          _body, bol_only, end_anchor = strip_anchors(ast)
          rule.bol_only = true if bol_only
          rule.end_anchor = true if end_anchor
        end
      end

      def strip_anchors(ast)
        children = ast.is_a?(Regexp::AST::Seq) ? ast.children.dup : [ast]
        bol_only = children.first.is_a?(Regexp::AST::Anchor) && children.first.kind == :bol
        end_anchor = children.last.is_a?(Regexp::AST::Anchor) && children.last.kind == :eol
        children.shift if bol_only
        children.pop if end_anchor
        body = if children.empty?
          Regexp::AST::Empty.new(loc: nil)
        elsif children.length == 1
          children.first
        else
          Regexp::AST::Seq.new(children: children, loc: nil)
        end
        [body, bol_only, end_anchor]
      end

      def subset_construction(nfa, ec, class_count)
        representatives = Array.new(class_count)
        ec.each_with_index { |class_id, byte| representatives[class_id] ||= byte }
        start_set = epsilon_closure(nfa, 1 << nfa.start)
        sets = [start_set]
        ids = { start_set => 0 }
        transitions = []
        accepts = []
        queue = [start_set]

        until queue.empty?
          set = queue.shift
          state_id = ids.fetch(set)
          transitions[state_id] ||= Array.new(class_count)
          accepts[state_id] = accepting_rules(nfa, set)
          class_count.times do |class_id|
            moved = move(nfa, set, representatives[class_id])
            next if moved.zero?
            closure = epsilon_closure(nfa, moved)
            destination = ids[closure]
            unless destination
              destination = sets.length
              limit = @spec.options.fetch(:max_dfa_states, 100_000)
              if destination >= limit
                raise CompileError.new("DFA state limit exceeded", diagnostic: Diagnostics.error("FLEXR-E006", "DFA state limit exceeded"))
              end
              ids[closure] = destination
              sets << closure
              queue << closure
            end
            transitions[state_id][class_id] = destination
          end
        end
        transitions.each { |row| row.map! { |value| value } }
        dfa = DFA.new(transitions: transitions, accepts: accepts, ec: ec, class_count: class_count, start: 0,
                      rule_ids: accepts.flatten.uniq.sort)
        Minimizer.minimize(dfa)
      end

      def epsilon_closure(nfa, set)
        closure = set
        stack = []
        nfa.states.each_index { |id| stack << id if (set & (1 << id)) != 0 }
        until stack.empty?
          state = stack.pop
          nfa.states[state].epsilon.each do |target|
            next if (closure & (1 << target)) != 0

            closure |= 1 << target
            stack << target
          end
        end
        closure
      end

      def move(nfa, set, byte)
        moved = 0
        nfa.states.each_index do |state|
          next if (set & (1 << state)).zero?

          nfa.states[state].transitions.each do |transition|
            next unless transition.lo <= byte && byte <= transition.hi

            moved |= 1 << transition.to
          end
        end
        moved
      end

      def accepting_rules(nfa, set)
        rules = []
        nfa.states.each_index do |state|
          next if (set & (1 << state)).zero?

          rules.concat(nfa.states[state].accepts)
        end
        rules.uniq.sort
      end

      def validate_rules
        if @spec.backend == :firstmatch && !@spec.options[:experimental]
          raise CompileError, "firstmatch requires option :experimental"
        end

        @spec.rules.each do |rule|
          if rule.patterns.empty?
            raise CompileError, "rule #{rule.index} has no pattern"
          end
          regexp = rule.patterns.first
          regexp = ::Regexp.new(::Regexp.escape(regexp)) if regexp.is_a?(String)
          next unless regexp.is_a?(::Regexp) && regexp.match?("")
          next if @spec.options[:allow_empty_match]

          diagnostic = Diagnostics.error("FLEXR-E005", "rule #{rule.index} can match an empty string")
          raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
        end
      end
    end
  end
end
