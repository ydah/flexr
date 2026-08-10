# frozen_string_literal: true

module Flexr
  module Automaton
    CompiledSpec = Struct.new(:machines, :rules, :states, :stats, :diagnostics, keyword_init: true)
    Machine = Struct.new(:dfa, :state_name, keyword_init: true)

    class Compiler
      def initialize(spec)
        @spec = spec
      end

      def compile
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        validate_rules
        state_names = effective_states
        machines = state_names.to_h do |state_name|
          rules = rules_for(state_name)
          [state_name, Machine.new(dfa: compile_machine(rules), state_name: state_name)]
        end
        stats = machines.transform_values { |machine| machine.dfa.stats }
        compiled = CompiledSpec.new(machines: machines, rules: @spec.rules, states: state_names, stats: stats)
        compiled.diagnostics = diagnostics_for(compiled, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at)
        compiled
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
        @active_rule_ids = rules.map(&:index)
        normalized = []
        rules.each do |rule|
          rule.pattern_conditions = []
          if reference_rule?(rule)
            validate_reference_patterns(rule)
            next
          end

          rule.patterns.each_with_index do |pattern, pattern_index|
            regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(::Regexp.escape(pattern.to_s))
            encoding = regexp.encoding == Encoding::BINARY ? Encoding::BINARY : @spec.encoding
            parser = Regexp::Parser.new(regexp.source, options: regexp.options, encoding: encoding,
                                        unicode: @spec.options[:unicode] == true)
            ast = parser.parse
            ast, bol_only, end_anchor = strip_anchors(ast)
            condition = Acceptance.new(rule_index: rule.index, pattern_index: pattern_index,
                                       bol_only: bol_only, end_anchor: end_anchor)
            rule.pattern_conditions[pattern_index] = condition
            normalized_ast = Regexp::Normalizer.new(ast, encoding: encoding, options: regexp.options).normalize
            normalized << [normalized_ast, condition]
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
        rule.patterns.any? { |pattern| reference_pattern?(pattern) }
      end

      def reference_pattern?(pattern)
        return false unless pattern.is_a?(::Regexp)
        return true if pattern.source.match?(/\\[pP]\{/) || pattern.source.match?(/\[:(?:\^)?[a-z]+:\]/)

        @spec.options[:unicode] == true && @spec.encoding != Encoding::BINARY &&
          pattern.source.match?(/\\[dDwWsS]/)
      end

      def validate_reference_patterns(rule)
        rule.patterns.each_with_index do |pattern, pattern_index|
          regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(::Regexp.escape(pattern.to_s))
          encoding = regexp.encoding == Encoding::BINARY ? Encoding::BINARY : @spec.encoding
          parser = Regexp::Parser.new(regexp.source, options: regexp.options, encoding: encoding,
                                      unicode: @spec.options[:unicode] == true)
          ast = parser.parse
          _body, bol_only, end_anchor = strip_anchors(ast)
          rule.pattern_conditions[pattern_index] = Acceptance.new(
            rule_index: rule.index, pattern_index: pattern_index, bol_only: bol_only, end_anchor: end_anchor
          )
        end
      end

      def strip_anchors(ast)
        children = ast.is_a?(Regexp::AST::Seq) ? ast.children.dup : [ast]
        children.shift while children.first.is_a?(Regexp::AST::Empty)
        children.pop while children.last.is_a?(Regexp::AST::Empty)
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
        if contains_anchor?(body)
          diagnostic = Diagnostics.error(
            "FLEXR-E009", "anchors are only valid at the outermost pattern boundaries",
            help: "split alternatives into separate rules or move ^/$ outside the alternation"
          )
          raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
        end
        [body, bol_only, end_anchor]
      end

      def contains_anchor?(node)
        return true if node.is_a?(Regexp::AST::Anchor)
        return false unless node.respond_to?(:children)

        node.children.any? { |child| contains_anchor?(child) }
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
              limit = 100_000 unless limit.is_a?(Integer) && limit.positive?
              if destination >= limit
                message = "DFA state limit exceeded while compiling rules #{@active_rule_ids.join(', ')}"
                diagnostic = Diagnostics.error("FLEXR-E006", message,
                                                help: "raise max_dfa_states or split the listed rules")
                raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
              end
              ids[closure] = destination
              sets << closure
              queue << closure
            end
            transitions[state_id][class_id] = destination
          end
        end
        transitions.each { |row| row.map! { |value| value } }
        rule_ids = accepts.flatten.map(&:rule_index).uniq.sort
        dfa = DFA.new(transitions: transitions, accepts: accepts, ec: ec, class_count: class_count, start: 0,
                      rule_ids: rule_ids)
        Minimizer.minimize(dfa)
      end

      def epsilon_closure(nfa, set)
        closure = set
        stack = []
        nfa.states.each_index { |id| stack << id if set.anybits?(1 << id) }
        until stack.empty?
          state = stack.pop
          nfa.states[state].epsilon.each do |target|
            next if closure.anybits?(1 << target)

            closure |= 1 << target
            stack << target
          end
        end
        closure
      end

      def move(nfa, set, byte)
        moved = 0
        nfa.states.each_index do |state|
          next if set.nobits?(1 << state)

          nfa.states[state].transitions.each do |transition|
            next unless byte.between?(transition.lo, transition.hi)

            moved |= 1 << transition.to
          end
        end
        moved
      end

      def accepting_rules(nfa, set)
        rules = []
        nfa.states.each_index do |state|
          next if set.nobits?(1 << state)

          rules.concat(nfa.states[state].accepts)
        end
        rules.uniq.sort_by { |acceptance| [acceptance.rule_index, acceptance.pattern_index] }
      end

      def validate_rules
        raise CompileError, "firstmatch requires option :experimental" if @spec.backend == :firstmatch && !@spec.options[:experimental]

        @spec.rules.each do |rule|
          raise CompileError, "rule #{rule.index} has no pattern" if rule.patterns.empty?
          next if @spec.options[:allow_empty_match]

          rule.patterns.each do |pattern|
            regexp = pattern.is_a?(String) ? ::Regexp.new(::Regexp.escape(pattern)) : pattern
            parse_regexp(regexp) if regexp.is_a?(::Regexp)
            next unless regexp.is_a?(::Regexp) && regexp.match?("")

            diagnostic = Diagnostics.error("FLEXR-E005", "rule #{rule.index} can match an empty string")
            raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
          end
        end
      end

      def parse_regexp(regexp)
        encoding = regexp.encoding == Encoding::BINARY ? Encoding::BINARY : @spec.encoding
        Regexp::Parser.new(regexp.source, options: regexp.options, encoding: encoding,
                           unicode: @spec.options[:unicode] == true).parse
      end

      def diagnostics_for(compiled, elapsed)
        diagnostics = []
        present = compiled.machines.values.flat_map do |machine|
          machine.dfa.accepts.filter_map { |acceptances| acceptances.min_by(&:rule_index)&.rule_index }
        end
        reference_rules = @spec.rules.select { |rule| reference_rule?(rule) && rule_active_anywhere?(rule) }
        present.concat(reference_rules.map(&:index))
        shadowers = shadowed_rules(compiled)
        diagnostics.concat(@spec.rules.reject { |rule| present.include?(rule.index) }.map do |rule|
          winners = shadowers.fetch(rule.index, []).uniq.sort
          suffix = winners.empty? ? "" : " (shadowed by rule #{winners.join(', ')})"
          Diagnostics.warning("FLEXR-W001", "rule #{rule.index} is unreachable#{suffix}", location: rule.location,
                              help: "remove it, reorder the rules, or make its language distinct")
        end)

        @spec.states.each_key do |state_name|
          next if state_name == :initial
          next unless rules_for(state_name).empty?

          diagnostics << Diagnostics.warning("FLEXR-W002", "state #{state_name.inspect} has no rules",
                                              help: "add a rule to the state or remove the unused state")
        end

        firstmatch_conflicts(@spec.rules).each do |left, right|
          diagnostics << Diagnostics.warning(
            "FLEXR-W010", "firstmatch rules #{left.index} and #{right.index} may change longest-match semantics",
            help: "use backend :table unless first-match compatibility is required"
          )
        end

        max_cells = compiled.stats.values.map { |stat| stat[:states] * stat[:classes] }.max.to_i
        if max_cells > 1_000_000
          diagnostics << Diagnostics.warning(
            "FLEXR-W011",
            "generated transition table is large",
            help: "use backend :direct, table compression, or split the specification"
          )
        end

        capture_rules.each do |rule|
          diagnostics << Diagnostics.warning(
            "FLEXR-W013",
            "rule #{rule.index} uses a capturing group; flexr treats it as non-capturing",
            help: "rewrite capturing groups as (?:...) and extract text in the action"
          )
        end

        undeclared_tokens.each do |token|
          diagnostics << Diagnostics.warning(
            "FLEXR-W014",
            "token #{token.inspect} is not declared by emits",
            help: "add the token to emits or remove the declaration if it is intentionally private"
          )
        end

        diagnostics.concat(variable_trailing_rules.map do |rule|
          Diagnostics.warning("FLEXR-W003", "rule #{rule.index} uses variable-length trailing context",
                              help: "make the body or followed_by expression fixed length when possible")
        end)

        if @spec.options.fetch(:accel, :auto) != :none
          diagnostics.concat(@spec.rules.select(&:trailing).map do |rule|
            Diagnostics.warning(
              "FLEXR-W012",
              "rule #{rule.index} cannot use region acceleration with trailing context",
              help: "remove trailing context or set accel: :none when the trade-off is intentional"
            )
          end)
        end

        if elapsed > 0.5
          diagnostics << Diagnostics.warning("FLEXR-W016", format("DFA construction took %.3fs", elapsed),
                                              help: "use generated mode for production startup")
        end
        diagnostics
      end

      def shadowed_rules(compiled)
        shadowers = Hash.new { |hash, key| hash[key] = [] }
        compiled.machines.each_value do |machine|
          machine.dfa.accepts.each do |acceptances|
            winner = acceptances.min_by(&:rule_index)&.rule_index
            next unless winner

            acceptances.each do |acceptance|
              next if acceptance.rule_index == winner

              shadowers[acceptance.rule_index] << winner
            end
          end
        end
        shadowers
      end

      def firstmatch_conflicts(rules)
        return [] unless @spec.backend == :firstmatch

        rules.combination(2).to_a
      end

      def rule_active_anywhere?(rule)
        @spec.states.keys.any? { |state_name| rules_for(state_name).include?(rule) }
      end

      def capture_rules
        @spec.rules.select do |rule|
          rule.patterns.any? do |pattern|
            source = pattern.respond_to?(:source) ? pattern.source : pattern.to_s
            source.match?(/(?<!\\)\((?!\?)/)
          end
        end
      end

      def undeclared_tokens
        return [] if Array(@spec.declared_tokens).empty?

        emitted = @spec.rules.flat_map do |rule|
          action = rule.action
          if action.is_a?(Array) && action.first == :emit
            [action.last]
          elsif action.is_a?(String)
            action.scan(/\bemit\s*\(?\s*:([A-Za-z_]\w*)/).flatten.map(&:to_sym)
          else
            []
          end
        end
        declared = Array(@spec.declared_tokens)
        emitted.uniq.reject { |token| declared.include?(token) }
      end

      def variable_trailing_rules
        @spec.rules.select do |rule|
          next false unless rule.trailing

          rule.patterns.any? { |pattern| variable_pattern?(pattern) } && variable_pattern?(rule.trailing)
        end
      end

      def variable_pattern?(pattern)
        source = pattern.respond_to?(:source) ? pattern.source : pattern.to_s
        source = source.gsub(/\\./, "")
        source.match?(/[+*]|\{\d+,\d*\}/)
      end
    end
  end
end
