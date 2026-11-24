# frozen_string_literal: true

require_relative "semantic_diff"

module Flexr
  module Source
    class RougeExporter
      Entry = Data.define(:regexp, :rule, :effect)
      TOKEN_NAME = /\A[A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9]*)*\z/
      DEFAULT_TOKENS = {
        "IDENT" => "Name", "IDENTIFIER" => "Name", "NAME" => "Name", "KEYWORD" => "Keyword",
        "STRING" => "Literal.String", "NUMBER" => "Literal.Number", "INTEGER" => "Literal.Number.Integer",
        "FLOAT" => "Literal.Number.Float", "COMMENT" => "Comment", "OPERATOR" => "Operator",
        "PUNCTUATION" => "Punctuation", "DELIMITER" => "Punctuation", "WHITESPACE" => "Text.Whitespace"
      }.freeze
      UNSUPPORTED_OPTIONS = %i[allow_empty_match indentation keyword_tables input_stack delegation dynamic_delimiters].freeze
      private_constant :Entry, :TOKEN_NAME, :DEFAULT_TOKENS, :UNSUPPORTED_OPTIONS

      def initialize(parsed, compiled:, backend:, token_map: {}, limit: 100_000)
        @parsed = parsed
        @compiled = compiled
        @backend = backend.to_sym
        @encoding = parsed.config.fetch(:encoding)
        @options = parsed.config.fetch(:options, {}).merge(max_dfa_states: limit)
        @token_map = validate_token_map(token_map)
      end

      def generate
        validate_spec!
        rules = @parsed.rules
        rules = rules.sort_by { |rule| [-rule.priority, rule.index] } unless @backend == :firstmatch
        entries = rules.flat_map do |rule|
          effect = action_effect(rule)
          rule.patterns.map { |pattern| Entry.new(rouge_pattern(pattern, rule), rule, effect) }
        end
        verify_order!(entries)
        source(entries)
      end

      private

      def validate_token_map(token_map)
        raise ArgumentError, "Rouge token map must be an object with tokens and channels mappings" unless
          token_map.is_a?(Hash) && (token_map.keys - %w[tokens channels]).empty?

        %w[tokens channels].to_h do |group|
          entries = token_map.fetch(group, {})
          raise ArgumentError, "Rouge token map #{group} must be an object mapping names to Rouge token names" unless
            entries.is_a?(Hash) && entries.all? { |key, token| key.is_a?(String) && token.is_a?(String) && TOKEN_NAME.match?(token) }

          [group, entries]
        end
      end

      def validate_spec!
        unsupported!("Rouge export requires UTF-8 input") unless @encoding == Encoding::UTF_8
        reject_runtime_overrides!
        if (option = UNSUPPORTED_OPTIONS.find { |name| @options[name] })
          unsupported!("Rouge export cannot represent #{option}")
        end
        unsupported!("Rouge export cannot represent EOF actions") unless @parsed.config.fetch(:eof_rules, {}).empty?
      end

      def reject_runtime_overrides!
        lexer = ::Prism.parse(@parsed.source).value.breadth_first_search do |node|
          node.is_a?(::Prism::ClassNode) && node.superclass && node.location.start_offset <= @parsed.first_dsl_offset &&
            @parsed.first_dsl_offset < node.location.end_offset &&
            node.superclass.location.slice.delete(" ").delete_prefix("::") == "Flexr::Lexer"
        end
        override = lexer&.body&.breadth_first_search do |node|
          next false unless node.is_a?(::Prism::DefNode)

          if node.receiver
            Lexer.respond_to?(node.name, true)
          else
            Lexer.method_defined?(node.name) || Lexer.private_method_defined?(node.name)
          end
        end
        return unless override

        location = override.name_loc
        unsupported!("Rouge export cannot represent the overridden #{override.name} method", [location.start_offset, location.end_offset])
      end

      def action_effect(rule)
        effect = ActionEffects.for_rule(rule)
        unsupported!("Rouge export cannot represent an opaque rule action", rule.span) unless effect
        targets = effect.state_operations.filter_map { |operation| operation[1] }
        target = targets.find { |name| !@parsed.states.key?(name) }
        unsupported!("Rouge export cannot enter unknown state #{target.inspect}", rule.span) if target
        effect
      end

      def rouge_pattern(pattern, rule)
        unsupported!("Rouge export cannot represent trailing context", rule.span) if rule.trailing
        unsupported!("Rouge export cannot represent pattern algebra", rule.span) if pattern.is_a?(Pattern)
        regexp = pattern.is_a?(String) ? ::Regexp.new(::Regexp.escape(pattern)) : pattern
        unsupported!("Rouge export cannot represent this regexp encoding", rule.span) if
          ![Encoding::US_ASCII, @encoding].include?(regexp.encoding) || regexp.options.anybits?(::Regexp::NOENCODING)
        unsupported!("Rouge export cannot represent Flexr Unicode property matching", rule.span) if
          Regexp::Matcher.reference?(regexp, encoding: @encoding, unicode: @options[:unicode] == true)

        ast = Regexp::Parser.new(regexp.source, options: regexp.options, encoding: @encoding).parse
        unsupported!("Rouge export cannot represent this context-dependent regexp", rule.span) if
          Regexp::AST.contextual?(ast) || Regexp::AST.anchors(ast).any? || Regexp::AST.absence?(ast)
        regexp
      end

      def verify_order!(entries)
        states = @parsed.states.each_with_index.to_h do |(name, state), index|
          [name, IR::State.new(name: name, inclusive: state.fetch(:inclusive), id: index, location: state.fetch(:location))]
        end
        rules = entries.each_with_index.map do |entry, index|
          IR::Rule.new(index: index, patterns: [entry.regexp], action: :skip, states: entry.rule.states, location: entry.rule.span)
        end
        projected_options = @options.except(:shortest_states)
        spec = IR::Spec.new(class_name: @parsed.class_name, backend: :firstmatch, token_kind: :array, encoding: @encoding,
                            options: projected_options, declared_tokens: [], states: states, rules: rules, eof_rules: {})
        projected = Automaton::Compiler.new(spec, retain_firstmatch_order: true).compile
        left = SemanticDiff::Input.from_source(parsed: @parsed, compiled: @compiled, backend: @backend)
        right = SemanticDiff::Input.new(compiled: projected, backend: :firstmatch, encoding: @encoding, options: projected_options,
                                       inclusive_states: left.inclusive_states,
                                       effects: rules.to_h { |rule| [rule.index, entries.fetch(rule.index).effect] })
        SemanticDiff.new(left, right, limit: @options.fetch(:max_dfa_states, 100_000)).states.each do |state_result|
          result = state_result.result
          next if result.status == :equal

          report_difference!(state_result.state, result, entries)
        end
      end

      def report_difference!(state, result, entries)
        if result.input
          rule = if result.left
            @parsed.rules.fetch(result.left.rule_index)
          elsif result.right
            entries.fetch(result.right.rule_index).rule
          end
          unsupported!("Rouge rule selection differs in state #{state.inspect} for #{result.input.inspect} at byte #{result.offset}", rule&.span)
        end

        unsupported!("Rouge rule selection could not be verified in state #{state.inspect}", @parsed.states.fetch(state).fetch(:location),
                     note: result.reason)
      end

      def source(entries)
        names = @parsed.class_name.split("::").reject(&:empty?).map(&:strip)
        unsupported!("Rouge export requires an ASCII constant path for the lexer class") unless
          names.any? && names.all? { |name| /\A[A-Z][A-Za-z0-9_]*\z/.match?(name) }

        names[-1] = "#{names.last}RougeLexer"
        class_name = names.join("::")
        lines = [%(require "rouge"), ""]
        (1...names.length).each do |size|
          namespace = names.first(size).join("::")
          lines.push("unless defined?(#{namespace})", "  module #{namespace}", "  end", "end", "")
        end
        lines << "class #{class_name} < ::Rouge::RegexLexer"
        @parsed.states.each do |state, config|
          lines << "  state #{state_name(state).inspect} do"
          entries.each do |entry|
            active = entry.rule.states
            next unless active.include?(state) || (config.fetch(:inclusive) && active.include?(:initial))

            lines.concat(rule_source(entry, "    "))
          end
          lines << "  end"
        end
        lines << "end"
        lines.join("\n") << "\n"
      end

      def rule_source(entry, indent)
        pattern = "::Regexp.new(#{entry.regexp.source.dump}, #{entry.regexp.options})"
        name = token_name(entry.effect)
        token = "(::Rouge::Token[#{name.dump}] || raise(ArgumentError, #{"unknown Rouge token #{name}".dump}))"
        return ["#{indent}rule #{pattern}, #{token}"] if entry.effect.state_operations.empty?

        lines = ["#{indent}rule #{pattern} do", "#{indent}  token #{token}"]
        entry.effect.state_operations.each do |operation, target|
          case operation
          when :push then lines << "#{indent}  push #{state_name(target).inspect}"
          when :pop then lines << "#{indent}  stack.length > 1 ? pop! : reset_stack"
          when :begin_state then lines << "#{indent}  goto #{state_name(target).inspect}"
          end
        end
        lines << "#{indent}end"
      end

      def state_name(name)
        name == :initial ? :root : :"flexr_#{name}"
      end

      def token_name(effect)
        return "Text" if effect.action == :skip

        channel = effect.channel.to_s
        token = effect.token.to_s
        @token_map.fetch("channels")[channel] || @token_map.fetch("tokens")[token] ||
          DEFAULT_TOKENS[channel.upcase] || DEFAULT_TOKENS[token.upcase] || "Text"
      end

      def unsupported!(message, location = nil, note: nil)
        location ||= @parsed.states.fetch(:initial).fetch(:location)
        diagnostic = Diagnostics.error("FLEXR-E036", message, location: location, note: note)
        raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
      end
    end
  end
end
