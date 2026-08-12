# frozen_string_literal: true

module Flexr
  module DSL
    DSL_METHODS = %i[rule state all_states on_eof emits backend token_kind encoding option accel].freeze
    AUTO_DIRECT_CELL_THRESHOLD = 100_000

    def inherited(child)
      super
      child.__flexr_reset!
    end

    def __flexr_reset!
      @__flexr_rules = []
      @__flexr_states = { initial: IR::State.new(name: :initial, inclusive: true, id: 0) }
      @__flexr_state_stack = []
      @__flexr_eof_rules = {}
      @__flexr_config = IR::Config.new(
        backend: :table, token_kind: :array, encoding: Encoding::UTF_8,
        options: {}, declared_tokens: [], states: @__flexr_states
      )
      @__flexr_compiled = nil
      @__flexr_generated = false
      @__flexr_generated_actions = []
      @__flexr_specification_frozen = false
      @__flexr_compile_mutex = Monitor.new
    end

    def rule(pattern, skip: false, emit: nil, followed_by: nil, &action)
      __flexr_mutate! do
        patterns = normalize_patterns(pattern)
        rule_action = ActionResolver.resolve(
          skip: skip, emit: emit, block: action, default: proc { emit(nil, text) }
        )
        states = @__flexr_state_stack.empty? ? [:initial] : @__flexr_state_stack.dup
        @__flexr_rules << IR::Rule.new(
          index: @__flexr_rules.length, patterns: patterns, trailing: normalize_trailing(followed_by),
          action: rule_action, states: states, bol_only: false, end_anchor: nil
        )
      end
      nil
    end

    def state(*names, inclusive: false, &block)
      raise ArgumentError, "state requires a block" unless block
      raise ArgumentError, "state requires a name" if names.empty?

      __flexr_mutate! do
        names.each do |name|
          symbol = name.to_sym
          existing = @__flexr_states[symbol]
          raise ArgumentError, "state #{symbol.inspect} already declared with inclusive: #{existing.inclusive}" if
            existing && existing.inclusive != inclusive
          @__flexr_states[symbol] ||= IR::State.new(
            name: symbol, inclusive: inclusive, id: @__flexr_states.length
          )
        end
        @__flexr_state_stack.concat(names.map(&:to_sym))
        begin
          class_eval(&block)
        ensure
          names.length.times { @__flexr_state_stack.pop }
        end
      end
    end

    def all_states(&)
      raise ArgumentError, "all_states requires a block" unless block_given?

      __flexr_mutate! do
        names = @__flexr_states.keys
        @__flexr_state_stack.concat(names)
        begin
          class_eval(&)
        ensure
          names.length.times { @__flexr_state_stack.pop }
        end
      end
    end

    def on_eof(&action)
      __flexr_mutate! do
        state_name = @__flexr_state_stack.last || :initial
        @__flexr_eof_rules[state_name] = action
      end
    end

    def emits(*tokens)
      __flexr_mutate! { @__flexr_config.declared_tokens.concat(tokens.flatten.map(&:to_sym)).uniq! }
    end

    def backend(name)
      __flexr_mutate! { @__flexr_config.backend = Configuration.backend!(name) }
    end

    def token_kind(name)
      __flexr_mutate! { @__flexr_config.token_kind = Configuration.token_kind!(name) }
    end

    def encoding(value)
      encoding = value.is_a?(Encoding) ? value : Encoding.find(value.to_s)
      unless [Encoding::UTF_8, Encoding::BINARY].include?(encoding)
        diagnostic = Diagnostics.error("FLEXR-E011", "flexr supports UTF-8 and BINARY only")
        raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
      end

      __flexr_mutate! { @__flexr_config.encoding = encoding }
    end

    def option(*values)
      __flexr_mutate! do
        values.each { |value| @__flexr_config.options[Configuration.option!(value)] = true }
      end
    end

    def accel(value)
      __flexr_mutate! { @__flexr_config.options[:accel] = Configuration.accelerator!(value) }
    end

    def compile!
      @__flexr_compile_mutex.synchronize do
        # The ivar is part of the generated/runtime class contract.
        # rubocop:disable Naming/MemoizedInstanceVariableName
        @__flexr_compiled ||= begin
          compiled = Automaton::Compiler.new(__flexr_spec).compile
          @__flexr_config.backend = auto_direct?(compiled) ? :direct : :table if @__flexr_config.backend == :auto
          freeze_specification!
          freeze_compiled!(compiled)
          compiled
        end
        # rubocop:enable Naming/MemoizedInstanceVariableName
      end
    end

    def dfa
      compile!
      __flexr_compiled
    end

    def __flexr_spec
      IR::Spec.new(
        class_name: name,
        superclass: superclass&.name,
        backend: @__flexr_config.backend,
        token_kind: @__flexr_config.token_kind,
        encoding: @__flexr_config.encoding,
        options: @__flexr_config.options,
        declared_tokens: @__flexr_config.declared_tokens,
        states: @__flexr_states,
        rules: @__flexr_rules,
        eof_rules: @__flexr_eof_rules,
        verbatim: nil
      )
    end

    attr_reader :__flexr_rules, :__flexr_states, :__flexr_config, :__flexr_compiled, :__flexr_generated_actions

    def __flexr_add_generated_eof(state, action)
      __flexr_mutate! { @__flexr_eof_rules[state.to_sym] = action }
    end

    def __flexr_set_compiled!(compiled)
      @__flexr_compile_mutex.synchronize do
        @__flexr_compiled = freeze_compiled!(compiled)
        freeze_specification!
      end
    end

    def __flexr_mark_generated!
      @__flexr_generated = true
    end

    def __flexr_bind_generated_action(index, action)
      raise FrozenSpecificationError, "generated actions can only be bound on a generated lexer" unless @__flexr_generated

      @__flexr_generated_actions[index] = action
    end

    def __flexr_generated?
      @__flexr_generated == true
    end

    private

    def __flexr_mutate!
      @__flexr_compile_mutex.synchronize do
        raise FrozenSpecificationError, "lexer specification is immutable after compilation" if
          @__flexr_specification_frozen

        yield
      end
    end

    def freeze_specification!
      @__flexr_rules.each do |rule|
        rule.patterns.freeze
        rule.states.freeze
        rule.pattern_conditions&.freeze
        rule.freeze
      end
      @__flexr_states.each_value(&:freeze)
      @__flexr_eof_rules.freeze
      @__flexr_rules.freeze
      @__flexr_states.freeze
      @__flexr_config.options.freeze
      @__flexr_config.declared_tokens.freeze
      @__flexr_config.freeze
      @__flexr_specification_frozen = true
    end

    def freeze_compiled!(compiled)
      compiled.machines.each_value(&:freeze)
      compiled.machines.freeze
      compiled.states.freeze
      compiled.stats.each_value(&:freeze)
      compiled.stats.freeze
      Array(compiled.diagnostics).each(&:freeze)
      compiled.diagnostics.freeze
      compiled.freeze
    end

    def normalize_patterns(pattern)
      values = pattern.is_a?(Array) ? pattern : [pattern]
      values.each do |value|
        unless value.is_a?(::Regexp) || value.is_a?(String)
          diagnostic = Diagnostics.error("FLEXR-E018", "rule pattern must be a Regexp, String, or Array")
          raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
        end
      end
      values
    end

    def normalize_trailing(value)
      case value
      when nil, ::Regexp
        value
      when String
        ::Regexp.new(::Regexp.escape(value))
      else
        diagnostic = Diagnostics.error("FLEXR-E018", "followed_by must be a Regexp or String")
        raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
      end
    end

    def auto_direct?(compiled)
      cells = compiled.stats.values.map { |stats| stats[:states] * stats[:classes] }.max.to_i
      cells > AUTO_DIRECT_CELL_THRESHOLD
    end
  end
end
