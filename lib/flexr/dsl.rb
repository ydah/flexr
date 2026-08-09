# frozen_string_literal: true

module Flexr
  module DSL
    DSL_METHODS = %i[rule state all_states on_eof emits backend token_kind encoding option accel].freeze

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
      @__flexr_compile_mutex = Mutex.new
    end

    def rule(pattern, skip: false, emit: nil, followed_by: nil, &action)
      patterns = normalize_patterns(pattern)
      rule_action = if skip
        :skip
      elsif emit
        [:emit, emit.to_sym]
      else
        action || proc { emit(nil, text) }
      end
      states = @__flexr_state_stack.empty? ? [:initial] : @__flexr_state_stack.dup
      @__flexr_rules << IR::Rule.new(
        index: @__flexr_rules.length, patterns: patterns, trailing: followed_by,
        action: rule_action, states: states, bol_only: false, end_anchor: nil
      )
      nil
    end

    def state(*names, inclusive: false, &block)
      raise ArgumentError, "state requires a block" unless block
      raise ArgumentError, "state requires a name" if names.empty?

      names.each do |name|
        symbol = name.to_sym
        @__flexr_states[symbol] ||= IR::State.new(name: symbol, inclusive: inclusive, id: @__flexr_states.length)
      end
      @__flexr_state_stack.concat(names.map(&:to_sym))
      class_eval(&block)
    ensure
      names.length.times { @__flexr_state_stack.pop } if names
    end

    def all_states(&block)
      state(*@__flexr_states.keys, &block)
    end

    def on_eof(&action)
      state_name = @__flexr_state_stack.last || :initial
      @__flexr_eof_rules[state_name] = action
    end

    def emits(*tokens)
      @__flexr_config.declared_tokens.concat(tokens.flatten.map(&:to_sym)).uniq!
    end

    def backend(name)
      @__flexr_config.backend = name.to_sym
    end

    def token_kind(name)
      value = name.to_sym
      raise ArgumentError, "unsupported token_kind: #{name}" unless %i[array struct yield].include?(value)

      @__flexr_config.token_kind = value
    end

    def encoding(value)
      encoding = value.is_a?(Encoding) ? value : Encoding.find(value.to_s)
      raise ArgumentError, "flexr supports UTF-8 and BINARY only" unless [Encoding::UTF_8, Encoding::BINARY].include?(encoding)

      @__flexr_config.encoding = encoding
    end

    def option(*values)
      values.each { |value| @__flexr_config.options[value.to_sym] = true }
    end

    def accel(value)
      @__flexr_config.options[:accel] = value.to_sym
    end

    def compile!
      @__flexr_compile_mutex.synchronize do
        @__flexr_compiled ||= Automaton::Compiler.new(__flexr_spec).compile
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

    attr_reader :__flexr_rules, :__flexr_states, :__flexr_config, :__flexr_compiled

    def __flexr_add_generated_eof(state, action)
      @__flexr_eof_rules[state.to_sym] = action
    end

    private

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
  end
end
