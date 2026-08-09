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
      klass.accel(config[:options][:accel]) if config[:options]&.key?(:accel)
      Array(config[:states]).each do |state|
        klass.state(state, inclusive: config.fetch(:inclusive_states, {}).fetch(state.to_sym, false)) { nil }
      end
      rules.each do |definition|
      klass.__flexr_add_generated_rule(definition)
      end
      config.fetch(:eof_rules, {}).each do |state, action|
        klass.__flexr_add_generated_eof(state, action)
      end
      klass
    end

    def install_compiled!(klass, payload)
      install!(klass, payload)
      machines = payload.fetch(:compiled).fetch(:machines).transform_values do |machine|
        dfa_data = machine.fetch(:dfa)
        dfa = Automaton::DFA.new(
          transitions: dfa_data.fetch(:transitions),
          accepts: dfa_data.fetch(:accepts),
          ec: dfa_data.fetch(:ec),
          class_count: dfa_data.fetch(:class_count),
          start: dfa_data.fetch(:start),
          rule_ids: dfa_data.fetch(:rule_ids),
          packed: dfa_data[:packed]
        )
        Automaton::Machine.new(dfa: dfa, state_name: machine.fetch(:state_name).to_sym)
      end
      compiled = Automaton::CompiledSpec.new(
        machines: machines,
        rules: klass.__flexr_rules,
        states: payload.fetch(:compiled).fetch(:states).map(&:to_sym),
        stats: payload.fetch(:compiled).fetch(:stats),
        diagnostics: []
      )
      klass.__flexr_set_compiled!(compiled)
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
        bol_only: definition.fetch(:bol_only, false), end_anchor: definition[:end_anchor],
        pattern_conditions: Array(definition[:pattern_conditions]).map do |condition|
          next unless condition

          Automaton::Acceptance.new(rule_index: condition[0], pattern_index: condition[1],
                                    bol_only: condition[2], end_anchor: condition[3])
        end
      )
    end
  end
end
