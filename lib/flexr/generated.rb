# frozen_string_literal: true

module Flexr
  module Generated
    module_function

    def install!(klass, payload)
      rules = payload.fetch(:rules)
      config = payload
      klass.__flexr_reset!
      klass.backend(config.fetch(:backend, :table))
      klass.token_kind(config.fetch(:token_kind, :array))
      klass.encoding(config.fetch(:encoding, Encoding::UTF_8))
      Array(config[:declared_tokens]).each { |token| klass.emits(token) }
      Array(config[:options]&.keys).each { |option| klass.option(option) }
      Array(config[:states]).each do |state| 
        klass.state(state, inclusive: config.fetch(:inclusive_states, {}).fetch(state.to_sym, false)) { }
      end
      rules.each do |definition|
        klass.__flexr_add_generated_rule(definition)
      end
      klass
    end
  end

  module DSL
    def __flexr_add_generated_rule(definition)
      action = definition.fetch(:action)
      @__flexr_rules << IR::Rule.new(
        index: definition.fetch(:index), patterns: Array(definition.fetch(:patterns)),
        trailing: definition[:trailing], action: action,
        states: Array(definition.fetch(:states)).map(&:to_sym),
        bol_only: definition.fetch(:bol_only, false), end_anchor: definition[:end_anchor]
      )
    end
  end
end
