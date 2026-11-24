# frozen_string_literal: true

require_relative "dfa_operations"
require_relative "keyword_tables"

module Flexr
  module Automaton
    class Compiler
      DEFAULT_CONSTRUCTION = :derivative

      def initialize(spec, construction: DEFAULT_CONSTRUCTION, retain_residuals: false)
        raise ArgumentError, "unknown DFA construction: #{construction.inspect}" unless %i[subset derivative].include?(construction)

        raise ArgumentError, "--residuals requires a longest-match backend" if retain_residuals && spec.backend == :firstmatch

        @spec = spec
        @construction = construction
        @retain_residuals = retain_residuals && construction == :derivative
      end

      def compile(lazy: false)
        @prebuilt_properties = true
        compile_spec(lazy: lazy)
      rescue CompileError => e
        raise unless @used_prebuilt_properties && e.diagnostic&.code == "FLEXR-E006"

        @prebuilt_properties = false
        compile_spec(lazy: lazy)
      end

      private

      def compile_spec(lazy:)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @used_prebuilt_properties = false
        @regexp_asts = {}
        @differences = {}
        @empty_absence_rules = {}
        @priorities = @spec.rules.to_h { |rule| [rule.index, rule.priority] }
        @pattern_dfas = {}
        @pattern_stats = {}
        @pattern_diagnostics = []
        @pattern_universe = nil
        @pattern_universe_dfa = nil
        @state_limit = @spec.options.fetch(:max_dfa_states, 100_000)
        @state_limit = 100_000 unless @state_limit.is_a?(Integer) && @state_limit.positive?
        directory = Flexr.cache_dir unless @retain_residuals || lazy
        @dfa_cache = directory && DfaCache.new(directory, @spec, @state_limit, construction: @construction)
        validate_rules
        state_names = effective_states
        machines = state_names.to_h do |state_name|
          rules = rules_for(state_name)
          residuals = nil
          retain = ->(descriptions) { residuals = descriptions } if @retain_residuals
          dfa = compile_machine(rules, lazy: lazy, &retain)
          plans = Accel.whole_token_plans(dfa, rules) if
            @spec.backend != :firstmatch && @spec.options[:accel] == :strscan
          memo_states, recovery_states = Analysis.backup_memo_states(dfa) unless @spec.backend == :firstmatch
          [state_name, Machine.new(dfa: dfa, state_name: state_name, whole_tokens: plans,
                                   residuals: residuals, backup_memo_states: memo_states,
                                   backup_recovery_states: recovery_states)]
        rescue CompileError => e
          e.diagnostic.location ||= @spec.states.fetch(state_name).location if e.diagnostic
          raise
        end
        return CompiledSpec.new(machines: machines, rules: @spec.rules, states: state_names, stats: {}, diagnostics: []) if lazy

        stats = machines.to_h do |name, machine|
          stat = machine.dfa.stats
          operations = rules_for(name).flat_map { |rule| @pattern_stats.fetch(rule.index, []) } unless @pattern_stats.empty?
          stat[:pattern_operations] = operations.freeze if operations&.any?
          [name, stat]
        end
        compiled = CompiledSpec.new(machines: machines, rules: @spec.rules, states: state_names, stats: stats)
        compiled.diagnostics = diagnostics_for(compiled, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) +
          @pattern_diagnostics
        compiled.diagnostics.concat(KeywordTables.diagnostics(compiled, @spec)) if @spec.options.key?(:keyword_tables)
        compiled
      end

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

      def compile_machine(rules, lazy:, &)
        return build_machine(rules, lazy: lazy, &) unless @dfa_cache

        resolved_patterns = rules.map do |rule|
          rule.patterns.map { |pattern| pattern.is_a?(Pattern) ? pattern : pattern_regexp(pattern) }
        end
        key = @dfa_cache.key(rules, resolved_patterns)
        if (entry = @dfa_cache.read(key))
          dfa, conditions, empty_absence = entry
          rules.zip(conditions).each do |rule, values|
            rule.pattern_conditions = values.map do |rule_index, pattern_index, bol_only, end_anchor|
              Acceptance.new(rule_index: rule_index, pattern_index: pattern_index, bol_only: bol_only, end_anchor: end_anchor)
            end
          end
          empty_absence.each { |index| @empty_absence_rules[index] = true }
          return dfa
        end

        dfa = build_machine(rules, resolved_patterns)
        conditions = rules.map { |rule| rule.pattern_conditions.map(&:to_a) }
        empty_absence = rules.filter_map { |rule| rule.index if @empty_absence_rules[rule.index] }
        @dfa_cache.write(key, dfa, conditions, empty_absence)
        dfa
      end

      def build_machine(rules, resolved_patterns = nil, lazy: false, &)
        @active_rules = rules
        normalized = []
        rules.each_with_index do |rule, rule_offset|
          rule.pattern_conditions = []
          first_pattern = normalized.length
          contains_absence = false
          patterns = resolved_patterns ? resolved_patterns.fetch(rule_offset) : rule.patterns
          patterns.each_with_index do |pattern, pattern_index|
            if pattern.is_a?(Pattern)
              body = Regexp::AST::EmbeddedDFA.new(@pattern_dfas.fetch([rule.index, pattern_index]))
              bol_only = end_anchor = false
            else
              regexp = pattern_regexp(pattern)
              ast = parse_regexp(regexp)
              contains_absence ||= Regexp::AST.absence?(ast)
              ast, bol_only, end_anchor = strip_anchors(ast)
              body = normalize_regexp(regexp, ast)
            end
            condition = Acceptance.new(rule_index: rule.index, pattern_index: pattern_index,
                                       bol_only: bol_only, end_anchor: end_anchor)
            rule.pattern_conditions[pattern_index] = condition
            normalized << [body, condition]
          end
          @empty_absence_rules[rule.index] = true if
            contains_absence && normalized[first_pattern..].all? { |ast, _| ast.is_a?(Regexp::AST::Fail) }
        rescue CompileError => e
          e.diagnostic.location ||= rule.location if e.diagnostic
          raise
        end
        return empty_dfa if normalized.empty?

        dfa = determinize(normalized, lazy: lazy, &)
        empty = empty_acceptance(dfa)
        if empty && !@spec.options[:allow_empty_match]
          rule = rules.find { |candidate| candidate.index == empty.rule_index }
          reject_empty_match!(Diagnostics.rule_label(rule), location: rule.location)
        end
        dfa
      end

      def determinize(patterns, operation: nil, lazy: false)
        if @construction == :derivative
          ordered = patterns.sort_by { |_, acceptance| acceptance_order(acceptance) }
          compiler = derivative_compiler
          rules = @active_rules
          dfa = compiler.compile(ordered, retain_residuals: block_given?, lazy: lazy) do |state, derived_operation|
            enforce_state_limit!(state, operation || derived_operation, rules: rules)
          end
          yield compiler.residuals if block_given?
          return dfa
        end

        nfa = NFABuilder.new(&method(:compile_difference)).build(patterns)
        ec, class_count = nfa.byte_classes.build
        subset_construction(nfa, ec, class_count, operation: operation)
      end

      def compile_difference(node)
        @differences[node] ||= begin
          operation = node.operation || "absence group"
          accept = Acceptance.new(rule_index: 0, pattern_index: 0)
          left = determinize([[node.left, accept]], operation: operation)
          right = determinize([[node.right, accept]], operation: operation)
          difference = DFAOperations.difference(left, right) { |state| enforce_state_limit!(state, operation) }
          Minimizer.minimize(difference)
        end
      end

      def compile_pattern_value(pattern, rule)
        @active_rules = [rule]
        value_dfa(normalized_value(pattern, rule), "pattern #{pattern.inspect}")
      end

      def normalized_value(pattern, rule)
        case pattern.operation
        when :literal
          regexp = pattern_regexp(pattern.operands.first)
          ast = parse_regexp(regexp)
          if Regexp::AST.anchors(ast).any? { |anchor| anchor.kind == :bol }
            diagnostic = Diagnostics.error("FLEXR-E009", "the beginning-of-line anchor is not allowed inside pattern values",
                                           help: "use an anchored regexp directly as a rule pattern")
            raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
          end
          normalize_regexp(regexp, ast)
        when :|, :+
          children = pattern.operands.map { |operand| normalized_value(operand, rule) }
          klass = pattern.operation == :| ? Regexp::AST::Alt : Regexp::AST::Seq
          klass.new(children: children, loc: nil)
        else
          Regexp::AST::EmbeddedDFA.new(compile_pattern_operation(pattern, rule))
        end
      end

      def compile_pattern_operation(pattern, rule)
        expression = pattern.inspect
        operands = pattern.operands.map { |operand| normalized_value(operand, rule) }
        case pattern.operation
        when :&, :-
          operation = pattern.operation == :& ? :intersection : :difference
          left, right = operands.map { |operand| value_dfa(operand, expression) }
        when :!
          operation = :complement
          left = pattern_universe_dfa(expression)
          right = value_dfa(operands.first, expression)
        when :upto
          operation = :upto
          left = pattern_universe_dfa(expression)
          ending = Regexp::AST::Seq.new(children: [pattern_universe, operands.first], loc: nil)
          right = value_dfa(ending, expression)
        end
        limit = ->(state, *) { enforce_state_limit!(state, expression) }
        product, overlap = if @construction == :derivative
          derive_pattern_product(left, right, operation, &limit)
        else
          DFAOperations.product(left, right, intersection: %i[intersection upto].include?(operation), &limit)
        end
        result = if operation == :upto && (product.starts || product.context_dependent_end?) && @construction == :derivative
          body = Regexp::AST::FirstEnding.new(Regexp::AST::EmbeddedDFA.new(product))
          value_dfa(body, expression)
        else
          Minimizer.minimize(operation == :upto ? DFAOperations.first_ending(product) : product)
        end
        record_pattern_operation(rule, operation, expression, left, right, product, result, overlap)
        result
      end

      def derivative_compiler
        require_relative "derivative_compiler"
        DerivativeCompiler.new
      end

      def derive_pattern_product(left, right, operation, &)
        left = Regexp::AST::EmbeddedDFA.new(left)
        right = Regexp::AST::EmbeddedDFA.new(right)
        intersection = Regexp::AST::Intersection.new(left: left, right: right)
        body = if %i[intersection upto].include?(operation)
          intersection
        else
          Regexp::AST::Difference.new(left: left, right: right)
        end
        patterns = [[body, Acceptance.new(rule_index: 0, pattern_index: 0)]]
        if operation == :difference
          overlap_probe = Acceptance.new(rule_index: 1, pattern_index: 0)
          patterns << [intersection, overlap_probe]
        end
        product = derivative_compiler.compile(patterns, minimize: false, &)
        return [product, false] unless overlap_probe && product.rule_ids.include?(overlap_probe.rule_index)

        accepts = product.accepts.map { |labels| labels.reject { |label| label.rule_index == overlap_probe.rule_index } }
        filtered = DFA.new(transitions: product.transitions, accepts: accepts, ec: product.ec,
                           class_count: product.class_count, start: product.start, starts: product.starts, rule_ids: [0])
        [filtered, true]
      end

      def pattern_universe
        @pattern_universe ||= Regexp::Normalizer.new(nil, encoding: @spec.encoding).universe
      end

      def pattern_universe_dfa(expression)
        @pattern_universe_dfa ||= value_dfa(pattern_universe, expression)
      end

      def value_dfa(node, expression)
        return node.dfa if node.is_a?(Regexp::AST::EmbeddedDFA)

        accept = Acceptance.new(rule_index: 0, pattern_index: 0)
        determinize([[node, accept]], operation: expression)
      end

      def record_pattern_operation(rule, operation, expression, left, right, product, result, overlap)
        if %i[intersection difference upto].include?(operation) && result.rule_ids.empty?
          message = if operation == :difference
            "pattern difference #{expression} is empty because the right operand covers the left operand"
          else
            "pattern #{operation} #{expression} is empty"
          end
          label = operation == :upto ? "subject alphabet" : "left operand"
          note = language_example(left, label)
          note = [note, language_example(right, "right operand")].compact.join(". ") if operation == :intersection
          diagnostic = Diagnostics.error("FLEXR-E029", message, location: rule.location, note: note)
          raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
        end
        if operation == :difference && !overlap
          @pattern_diagnostics << Diagnostics.warning(
            "FLEXR-W021", "pattern subtraction #{expression} removes no input",
            location: rule.location, note: language_example(right, "right operand")
          )
        end

        sizes = [left.states, right.states].freeze
        (@pattern_stats[rule.index] ||= []) << {
          operation: operation, expression: expression.freeze, operand_states: sizes,
          product_states: product.states, result_states: result.states
        }.freeze
        return unless product.states >= 16 && product.states > sizes.max * 2

        @pattern_diagnostics << Diagnostics.warning(
          "FLEXR-W011", "pattern #{operation} #{expression} expands the DFA",
          location: rule.location,
          note: "operands have #{sizes.join(' and ')} states. The product visits #{product.states} states and minimizes to #{result.states}"
        )
      end

      def language_example(dfa, label)
        sample = Analysis.shortest_input(dfa)
        return "#{label} accepts no input" unless sample

        "#{label} accepts #{sample.force_encoding(@spec.encoding).inspect}"
      end

      def pattern_regexp(pattern)
        pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(::Regexp.escape(pattern.to_s))
      end

      def enforce_state_limit!(state, operation, rules: @active_rules)
        return if state < @state_limit

        labels = rules.map { |rule| Diagnostics.rule_label(rule) }.join(", ")
        subject = operation ? "#{operation} in #{labels}" : labels
        diagnostic = Diagnostics.error("FLEXR-E006", "DFA state limit exceeded while compiling #{subject}",
                                       help: "raise max_dfa_states or split the listed rules")
        raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
      end

      def empty_dfa
        DFA.new(transitions: [[nil]], accepts: [[]], ec: Array.new(256, 0), class_count: 1, start: 0, rule_ids: [])
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
        [body, bol_only, end_anchor]
      end

      def subset_construction(nfa, ec, class_count, operation:)
        closures = {}
        closure_for = lambda do |state|
          closures[state] ||= epsilon_closure_for(nfa, state)
        end
        transition_closures = indexed_transition_closures(nfa, ec, closure_for)
        start_set = closure_for.call(nfa.start)
        sets = [start_set]
        ids = { start_set => 0 }
        transitions = []
        accepts = []
        queue = [start_set]
        queue_index = 0
        while queue_index < queue.length
          set = queue.fetch(queue_index)
          queue_index += 1
          state_id = ids.fetch(set)
          transitions[state_id] ||= Array.new(class_count)
          accepts[state_id] = accepting_rules(nfa, set)
          move_closures(set, transition_closures).each do |class_id, closure|
            destination = ids[closure]
            unless destination
              destination = sets.length
              enforce_state_limit!(destination, operation) if destination >= @state_limit
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

      def epsilon_closure_for(nfa, state)
        closure = 1 << state
        stack = [state]
        until stack.empty?
          current = stack.pop
          nfa.states[current].epsilon.each do |target|
            next if closure.anybits?(1 << target)

            closure |= 1 << target
            stack << target
          end
        end
        closure
      end

      def indexed_transition_closures(nfa, ec, closure_for)
        nfa.states.map do |state|
          raw = {}
          state.transitions.each do |transition|
            transition.lo.upto(transition.hi).map { |byte| ec.fetch(byte) }.uniq.each do |class_id|
              raw[class_id] = raw.fetch(class_id, 0) | (1 << transition.to)
            end
          end
          raw.transform_values do |targets|
            each_state_id(targets).reduce(0) { |closure, target| closure | closure_for.call(target) }
          end
        end
      end

      def move_closures(set, transition_closures)
        each_state_id(set).with_object({}) do |state, moves|
          transition_closures.fetch(state).each do |class_id, closure|
            moves[class_id] = moves.fetch(class_id, 0) | closure
          end
        end
      end

      def accepting_rules(nfa, set)
        rules = each_state_id(set).with_object([]) do |state, result|
          result.concat(nfa.states[state].accepts)
        end
        rules.uniq.sort_by { |acceptance| acceptance_order(acceptance) }
      end

      def acceptance_order(acceptance)
        [-@priorities.fetch(acceptance.rule_index, 0), acceptance.rule_index, acceptance.pattern_index]
      end

      def each_state_id(set)
        return enum_for(__method__, set) unless block_given?

        remaining = set
        until remaining.zero?
          bit = remaining & -remaining
          yield bit.bit_length - 1
          remaining ^= bit
        end
      end

      def validate_rules
        @spec.rules.each do |rule|
          raise CompileError, "rule #{rule.index} has no pattern" if rule.patterns.empty?
          if @spec.backend == :firstmatch && !rule.priority.zero?
            diagnostic = Diagnostics.error("FLEXR-E018", "explicit priority requires a longest-match backend",
                                           help: "use backend :table, :direct, or :auto")
            raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
          end
          validate_trailing(rule) if rule.trailing

          rule.patterns.each_with_index do |pattern, index|
            if pattern.is_a?(Pattern)
              validate_pattern_body(pattern, rule, index)
              next
            end

            regexp = pattern.is_a?(String) ? ::Regexp.new(::Regexp.escape(pattern)) : pattern
            next unless regexp.is_a?(::Regexp)

            ast = parse_regexp(regexp)
            has_absence = Regexp::AST.absence?(ast)
            if has_absence && @spec.backend == :firstmatch
              diagnostic = Diagnostics.error("FLEXR-E014", "absence groups in rule patterns require a longest-match backend",
                                             help: "use backend :table, :direct, or :auto")
              raise UnsupportedRegexpError.new(diagnostic.message, diagnostic: diagnostic)
            end
            contextual = Regexp::AST.contextual?(ast)
            if contextual && (@spec.backend == :firstmatch || !regexp.names.empty?)
              contexts = rule.contextual_patterns ||= []
              contexts[index] = prepare_contextual_regexp(rule, regexp, ast)
            end
            prepare_capture_pattern(rule, index, regexp) unless regexp.names.empty?
            next if @spec.options[:allow_empty_match] || contextual
            next unless has_absence ? Regexp::AST.nullable?(ast) : regexp.match?("")

            reject_empty_match!(Diagnostics.rule_label(rule))
          end
        rescue CompileError => e
          e.diagnostic.location ||= rule.location if e.diagnostic
          raise
        end
      end

      def prepare_contextual_regexp(rule, regexp, ast)
        @active_rules = [rule]
        _, _, terminal_line_end = strip_anchors(ast)
        encoding = regexp.encoding == Encoding::BINARY ? Encoding::BINARY : @spec.encoding
        unless regexp.names.empty?
          ast = Regexp::Parser.new(regexp.source, encoding: encoding, options: regexp.options,
                                   unicode: @spec.options[:unicode] == true, preserve_captures: true).parse
        end
        body = Regexp::Normalizer.new(ast, encoding: encoding, subject_encoding: @spec.encoding, prebuilt_properties: false).normalize
        options = { encoding: encoding, unicode: @spec.options[:unicode] == true }
        anchors = Regexp::AST.anchors(ast)
        left_context = anchors.any? { |anchor| Regexp::AST.left_anchor?(anchor) }
        start = left_context ? '\G' : '\A'
        reference = contextual_reference(regexp, options, start, terminal_line_end ? "$" : "")
        if anchors.any? { |anchor| %i[line_start line_end eof final_eol].include?(anchor.kind) }
          before_lf = terminal_line_end ? '(?=\n)' : ""
          invalid_eof = contextual_reference(regexp, options.merge(invalid_eof: true), start, before_lf)
        end
        compiler = ContextualRegexpCompiler.new { |state| enforce_state_limit!(state, "regexp context") }
        compiler.compile(body, reference, invalid_eof: invalid_eof, left_context: left_context)
      end

      def contextual_reference(regexp, options, start, ending)
        reference = Unicode::ReferenceRegexp.compiled(regexp, **options)
        ::Regexp.new("#{start}(?:#{reference.source})#{ending}", reference.options)
      end

      def prepare_capture_pattern(rule, index, regexp)
        encoding = regexp.encoding == Encoding::BINARY ? Encoding::BINARY : @spec.encoding
        pattern = if rule.contextual_patterns&.[](index)
          rule.contextual_patterns.fetch(index)
        elsif @spec.backend == :firstmatch
          regexp
        else
          options = { encoding: encoding, unicode: @spec.options[:unicode] == true, anchored: true }
          regular = Unicode::ReferenceRegexp.compiled(regexp, **options)
          if Regexp::AST.next_byte_assertion?(parse_regexp(regexp))
            [regular, Unicode::ReferenceRegexp.compiled(regexp, **options, following_lf: true)].freeze
          else
            regular
          end
        end
        (rule.capture_patterns ||= [])[index] = pattern
      rescue RegexpError, EncodingError => e
        diagnostic = Diagnostics.error("FLEXR-E014", "cannot replay named captures with Ruby",
                                       note: e.message, help: "split the rule or use non-capturing groups")
        raise UnsupportedRegexpError.new(diagnostic.message, diagnostic: diagnostic)
      end

      def validate_pattern_body(pattern, rule, index)
        if @spec.backend == :firstmatch
          diagnostic = Diagnostics.error("FLEXR-E014", "pattern values in rule bodies require a longest-match backend",
                                         help: "use backend :table, :direct, or :auto")
          raise UnsupportedRegexpError.new(diagnostic.message, diagnostic: diagnostic)
        end
        dfa = compile_pattern_value(pattern, rule)
        reject_empty_match!(Diagnostics.rule_label(rule)) if
          !@spec.options[:allow_empty_match] && empty_acceptance(dfa)
        @pattern_dfas[[rule.index, index]] = dfa
      end

      def validate_trailing(rule)
        if rule.trailing.is_a?(Pattern)
          rule.trailing_dfa = compile_pattern_value(rule.trailing, rule)
          reject_empty_match!("trailing context for #{Diagnostics.rule_label(rule)}") if
            empty_acceptance(rule.trailing_dfa)
          return
        end
        return unless rule.trailing.is_a?(::Regexp)

        ast = parse_regexp(rule.trailing)
        return unless Regexp::AST.absence?(ast) || Regexp::AST.next_byte_assertion?(ast) || Regexp::AST.contextual?(ast)
        @active_rules = [rule]
        body, bol_only, end_anchor = strip_anchors(ast)
        condition = Acceptance.new(rule_index: 0, pattern_index: 0, bol_only: bol_only, end_anchor: end_anchor)
        rule.trailing_dfa = determinize([[normalize_regexp(rule.trailing, body), condition]])
        return unless empty_acceptance(rule.trailing_dfa)

        reject_empty_match!("trailing context for #{Diagnostics.rule_label(rule)}")
      end

      def empty_acceptance(dfa)
        (dfa.starts || [dfa.start]).each do |state|
          acceptance = dfa.accepts.fetch(state).first
          return acceptance if acceptance
        end
        nil
      end

      def reject_empty_match!(label, location: nil)
        diagnostic = Diagnostics.error("FLEXR-E005", "#{label} can match an empty string", location: location)
        raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
      end

      def parse_regexp(regexp)
        encoding = regexp.encoding == Encoding::BINARY ? Encoding::BINARY : @spec.encoding
        @regexp_asts[regexp] ||= Regexp::Parser.new(regexp.source, options: regexp.options, encoding: encoding,
                                                  unicode: @spec.options[:unicode] == true).parse
      end

      def normalize_regexp(regexp, ast)
        encoding = regexp.encoding == Encoding::BINARY ? Encoding::BINARY : @spec.encoding
        normalizer = Regexp::Normalizer.new(ast, encoding: encoding, subject_encoding: @spec.encoding,
                                            options: regexp.options, prebuilt_properties: @prebuilt_properties)
        normalized = normalizer.normalize
        @used_prebuilt_properties ||= normalizer.used_prebuilt_properties
        normalized
      end

      def diagnostics_for(compiled, elapsed)
        diagnostics = []
        contextual = {}
        present = compiled.machines.flat_map do |state_name, machine|
          dfa = machine.dfa
          next dfa.accepts.filter_map { |acceptances| acceptances.first&.rule_index } unless dfa.context_dependent_end?

          # DFA acceptance order alone cannot establish shadowing with trailing or first-match rules.
          next dfa.rule_ids if @spec.backend == :firstmatch || rules_for(state_name).any?(&:trailing)
          if dfa.lookahead?
            require_relative "lookahead_reachability"

            proof = contextual[state_name] = LookaheadReachability.new(dfa, encoding: @spec.encoding, limit: @state_limit)
            next proof.winners
          end

          Analysis.contextual_winners(dfa)
        end
        shadowers = shadowed_rules(compiled)
        rules_by_index = @spec.rules.to_h { |rule| [rule.index, rule] }
        unreachable = @spec.rules.reject { |rule| present.include?(rule.index) }
        examples = unreachable_examples(compiled, unreachable, rules_by_index)
        unreachable.each do |rule|
          next if examples.key?(rule.index)

          sample = lookahead_example(compiled, contextual, rule.index, rules_by_index)
          examples[rule.index] = sample if sample
        end
        diagnostics.concat(unreachable.filter_map do |rule|
          example = examples[rule.index]
          next if example && example.fetch(:winner) == rule.index

          winner_indices = @spec.backend == :firstmatch || @spec.rules.any?(&:trailing) ? [] : shadowers.fetch(rule.index, [])
          winners = winner_indices.uniq.sort.map { |index| Diagnostics.rule_label(rules_by_index.fetch(index)) }
          suffix = winners.empty? ? "" : " (shadowed by #{winners.join(', ')})"
          Diagnostics.warning("FLEXR-W001", "#{Diagnostics.rule_label(rule)} is unreachable#{suffix}", location: rule.location,
                              help: "remove it, reorder the rules, or make its language distinct",
                              note: example&.fetch(:note) || empty_absence_note(rule))
        end)
        if @spec.options[:warn_level] == :all
          diagnostics.concat(overlap_diagnostics(compiled, rules_by_index))
          diagnostics.concat(backup_diagnostics(compiled)) unless @spec.backend == :firstmatch
        end

        @spec.states.each do |state_name, state|
          next if state_name == :initial
          next unless rules_for(state_name).empty?

          diagnostics << Diagnostics.warning("FLEXR-W002", "state #{state_name.inspect} has no rules",
                                              location: state.location,
                                              help: "add a rule to the state or remove the unused state")
        end

        firstmatch_conflicts(@spec.rules).each do |left, right|
          diagnostics << Diagnostics.warning(
            "FLEXR-W010", "firstmatch #{Diagnostics.rule_label(left)} and #{Diagnostics.rule_label(right)} may change longest-match semantics",
            location: right.location,
            help: "use backend :table unless first-match compatibility is required"
          )
        end

        largest_state, max_cells = compiled.stats.map { |name, stat| [name, stat[:states] * stat[:classes]] }.max_by(&:last)
        if max_cells && max_cells > 1_000_000
          diagnostics << Diagnostics.warning(
            "FLEXR-W011",
            "generated transition table is large",
            location: @spec.states.fetch(largest_state).location,
            help: "use backend :direct, table compression, or split the specification"
          )
        end

        capture_rules.each do |rule|
          diagnostics << Diagnostics.warning(
            "FLEXR-W013",
            "#{Diagnostics.rule_label(rule)} uses a capturing group; flexr treats it as non-capturing",
            location: rule.location,
            help: "rewrite capturing groups as (?:...) and extract text in the action"
          )
        end

        undeclared_token_rules.each do |token, rule|
          diagnostics << Diagnostics.warning(
            "FLEXR-W014",
            "token #{token.inspect} is not declared by emits",
            location: rule.location,
            help: "add the token to emits or remove the declaration if it is intentionally private"
          )
        end

        diagnostics.concat(variable_trailing_rules.map do |rule|
          Diagnostics.warning("FLEXR-W003", "#{Diagnostics.rule_label(rule)} uses variable-length trailing context",
                              location: rule.location,
                              help: "make the body or followed_by expression fixed length when possible")
        end)

        if @spec.options.fetch(:accel, :auto) != :none
          diagnostics.concat(@spec.rules.select(&:trailing).map do |rule|
            Diagnostics.warning(
              "FLEXR-W012",
              "#{Diagnostics.rule_label(rule)} cannot use region acceleration with trailing context",
              location: rule.location,
              help: "remove trailing context or set accel: :none when the trade-off is intentional"
            )
          end)
        end

        if elapsed > 0.5
          diagnostics << Diagnostics.warning("FLEXR-W016", format("DFA construction took %.3fs", elapsed),
                                              location: @spec.states.fetch(:initial).location,
                                              help: "use generated mode for production startup")
        end
        diagnostics
      end

      def backup_diagnostics(compiled)
        compiled.machines.filter_map do |state, machine|
          backup = Analysis.backup(machine.dfa)
          next unless backup.unbounded?

          Diagnostics.warning("FLEXR-W023", "state #{state.inspect} has unbounded DFA backup",
                              location: @spec.states.fetch(state).location,
                              note: "body DFA example: #{backup.example.inspect} followed by repetitions of #{backup.cycle.inspect}")
        end
      end

      def empty_absence_note(rule)
        return unless @empty_absence_rules[rule.index]

        'this language is empty; an absence group that excludes "" cannot match because every string contains ""'
      end

      def overlap_diagnostics(compiled, rules_by_index)
        # shortcut: verify one shortest body and trailing candidate per rule; search alternatives if rejected examples need coverage.
        compiled.machines.flat_map do |state_name, machine|
          active_rules = rules_for(state_name)
          trailing_dfas = diagnostic_trailing_dfas(active_rules)
          next [] unless trailing_dfas

          has_trailing = !trailing_dfas.empty?
          candidates = Analysis.shadowing_examples(machine.dfa, machine.dfa.rule_ids,
                                                    include_empty: has_trailing, include_unshadowed: has_trailing)
          candidates.filter_map do |index, (bytes, winner)|
            if (trailing = trailing_dfas[index])
              suffix = Analysis.shortest_input(trailing)
              next unless suffix

              bytes += suffix
            end
            input = bytes.dup.force_encoding(@spec.encoding)
            next if input.empty? || !input.valid_encoding?

            rule = rules_by_index.fetch(index)
            length = input.bytesize
            if has_trailing
              result = Analysis.trailing_example(machine.dfa, active_rules, rule, input, trailing_dfas,
                                                  encoding: @spec.encoding, unicode: @spec.options[:unicode] == true,
                                                  firstmatch: @spec.backend == :firstmatch, same_length: true)
              next unless result && result.first != index

              winner, length, lookahead = result
            elsif @spec.backend == :firstmatch
              result = Analysis.firstmatch_example(active_rules, rule, input, encoding: @spec.encoding,
                                                    unicode: @spec.options[:unicode] == true, same_length: true)
              next unless result && result.first != index

              winner, length = result
            end
            winner_rule = rules_by_index.fetch(winner)
            selected = Diagnostics.rule_label(winner_rule)
            state = state_name == :initial ? "" : " in state #{state_name.inspect}"
            size = "#{length} #{length == 1 ? 'byte' : 'bytes'}"
            tie = priority_tie_reason(winner_rule, rule)
            reason = if has_trailing
              selection = @spec.backend == :firstmatch ? "first match wins" : "same total length, #{tie}"
              "#{selection}; matched #{size}, looked ahead #{lookahead} #{lookahead == 1 ? 'byte' : 'bytes'}"
            elsif @spec.backend == :firstmatch
              "first match wins, matched #{size}"
            else
              "#{size}, #{tie}"
            end
            match_size = has_trailing ? "total length" : "length"
            help = if winner_rule.priority == rule.priority
              "reorder the rules if the later rule should take priority"
            else
              "raise the losing rule's priority if it should win equal-length matches"
            end
            Diagnostics.info("FLEXR-I001", "#{Diagnostics.rule_label(rule)} overlaps #{selected} at the same #{match_size}",
                             location: rule.location, help: help,
                             note: "example: #{input.inspect} selects #{selected}#{state} (#{reason})")
          end
        end
      end

      def lookahead_example(compiled, contextual, index, rules)
        contextual.each do |state, proof|
          next unless (input = proof.example(index))

          dfa = compiled.machines.fetch(state).dfa
          matches = Analysis.dfa_match_lengths(dfa, input, encoding: @spec.encoding)
          next unless matches.any? { |rule, _| rule == index }

          winner, size = matches.max_by { |rule, length| [length, rules.fetch(rule).priority, -rule] }
          state_name = " in state #{state.inspect}" unless state == :initial
          selection = Diagnostics.rule_label(rules.fetch(winner))
          note = "example: #{input.inspect} selects #{selection}#{state_name} (longest match, #{size} bytes)"
          return { note: note, winner: winner }
        end
        nil
      end

      def unreachable_examples(compiled, rules, rules_by_index)
        return {} if rules.empty?

        indices = rules.map(&:index)
        examples = {}
        compiled.machines.each do |state_name, machine|
          active_rules = rules_for(state_name)
          # shortcut: verify only the shortest candidate; search alternatives if rejected examples need coverage.
          candidates = Analysis.shadowing_examples(machine.dfa, indices, include_empty: active_rules.any?(&:trailing))
          next if candidates.empty?

          trailing_dfas = diagnostic_trailing_dfas(active_rules)
          next unless trailing_dfas

          candidates.each do |index, (bytes, winner)|
            if (trailing = trailing_dfas[index])
              suffix = Analysis.shortest_input(trailing)
              next unless suffix

              bytes += suffix
            end
            input = bytes.dup.force_encoding(@spec.encoding)
            next if input.empty? || !input.valid_encoding?
            next if examples[index] && examples[index][1] == index

            length = lookahead = nil
            if !trailing_dfas.empty?
              result = Analysis.trailing_example(machine.dfa, active_rules, rules_by_index.fetch(index), input, trailing_dfas,
                                                  encoding: @spec.encoding, unicode: @spec.options[:unicode] == true,
                                                  firstmatch: @spec.backend == :firstmatch)
              next unless result

              winner, length, lookahead = result
            elsif @spec.backend == :firstmatch
              result = Analysis.firstmatch_example(active_rules, rules_by_index.fetch(index), input,
                                                    encoding: @spec.encoding, unicode: @spec.options[:unicode] == true)
              next unless result

              winner, length = result
            end
            next if winner != index && examples[index] && examples[index].first.bytesize <= input.bytesize

            examples[index] = [input, winner, state_name, length, lookahead]
          end
        end
        examples.to_h do |index, (input, winner, state_name, length, lookahead)|
          winner_rule = rules_by_index.fetch(winner)
          rule = rules_by_index.fetch(index)
          state = state_name == :initial ? "" : " in state #{state_name.inspect}"
          reason = if @spec.backend == :firstmatch
            "first match wins, matched #{length} #{length == 1 ? 'byte' : 'bytes'}"
          elsif lookahead
            size = "#{length} #{length == 1 ? 'byte' : 'bytes'}"
            selection = if winner_rule.priority == rule.priority
              "longest total match, then rule order"
            else
              "longest total match, then priority #{winner_rule.priority} and rule order"
            end
            "#{selection}; matched #{size}"
          else
            "same length, #{priority_tie_reason(winner_rule, rule)}"
          end
          reason += ", looked ahead #{lookahead} #{lookahead == 1 ? 'byte' : 'bytes'}" if lookahead
          note = "example: #{input.inspect} selects #{Diagnostics.rule_label(winner_rule)}#{state} (#{reason})"
          [index, { note: note, winner: winner }]
        end
      end

      def priority_tie_reason(winner, loser)
        return "earlier rule wins" if winner.priority == loser.priority

        "priority #{winner.priority} beats #{loser.priority}"
      end

      def diagnostic_trailing_dfas(rules)
        rules.select(&:trailing).to_h do |rule|
          dfa = rule.trailing_dfa || Flexr.compile_pattern(rule.trailing, encoding: @spec.encoding,
                                                          options: { unicode: @spec.options[:unicode] == true })
          [rule.index, dfa]
        end
      rescue CompileError
        # shortcut: omit examples for trailing patterns the runtime cannot compile, until that matcher supports them.
        nil
      end

      def shadowed_rules(compiled)
        shadowers = Hash.new { |hash, key| hash[key] = [] }
        compiled.machines.each_value do |machine|
          machine.dfa.accepts.each do |acceptances|
            acceptances = acceptances.select { |label| label.valid_end?(nil) } if machine.dfa.context_dependent_end?
            winner = acceptances.first&.rule_index
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

      def capture_rules
        @spec.rules.select { |rule| rule.patterns.any? { |pattern| pattern_capture?(pattern) } }
      end

      def pattern_capture?(pattern)
        return pattern.operands.any? { |operand| pattern_capture?(operand) } if pattern.is_a?(Pattern)

        pattern.is_a?(::Regexp) && capturing_group?(pattern.source)
      end

      def capturing_group?(source)
        escaped = false
        in_class = false
        source.each_char.with_index do |character, index|
          if escaped
            escaped = false
            next
          end
          if character == "\\"
            escaped = true
          elsif character == "["
            in_class = true
          elsif character == "]"
            in_class = false
          elsif character == "(" && !in_class
            return true unless source[index + 1] == "?"
          end
        end
        false
      end

      def undeclared_token_rules
        declared = Array(@spec.declared_tokens)
        return {} if declared.empty?

        emitted = @spec.rules.each_with_object({}) do |rule, rules_by_token|
          next if rule.channel

          action = rule.action
          tokens = if action.is_a?(Array) && action.first == :emit
            [action.last]
          elsif action.is_a?(String)
            action.scan(/\bemit\s*\(?\s*:([A-Za-z_]\w*)/).flatten.map(&:to_sym)
          else
            []
          end
          tokens.each { |token| rules_by_token[token] ||= rule }
        end
        emitted.except(*declared)
      end

      def variable_trailing_rules
        @spec.rules.select do |rule|
          next false unless rule.trailing

          rule.patterns.any? { |pattern| variable_pattern?(pattern) } && variable_pattern?(rule.trailing)
        end
      end

      def variable_pattern?(pattern)
        return variable_algebra?(pattern) if pattern.is_a?(Pattern)
        return false unless pattern.is_a?(::Regexp)
        return true if Regexp::AST.absence?(@regexp_asts[pattern])

        source = pattern.source.gsub(/\\./, "")
        source.match?(/[+*]|\{\d+,\d*\}/)
      end

      def variable_algebra?(pattern)
        operands = pattern.operands
        case pattern.operation
        when :literal, :+
          operands.any? { |operand| variable_pattern?(operand) }
        when :|
          operands.any? { |operand| variable_pattern?(operand) } ||
            operands.filter_map { |operand| literal_width(operand) }.uniq.length > 1
        when :&
          operands.all? { |operand| variable_pattern?(operand) }
        when :-
          variable_pattern?(operands.first)
        else
          true
        end
      end

      def literal_width(pattern)
        return pattern.bytesize if pattern.is_a?(String)
        return unless pattern.is_a?(Pattern) && %i[literal +].include?(pattern.operation)

        widths = pattern.operands.map { |operand| literal_width(operand) }
        widths.sum unless widths.include?(nil)
      end
    end
  end
end
