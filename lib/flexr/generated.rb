# frozen_string_literal: true

module Flexr
  module Generated
    ARTIFACT_SCHEMA_VERSION = 2
    RUNTIME_ABI_VERSION = 2

    module_function

    def artifact_metadata
      {
        schema_version: ARTIFACT_SCHEMA_VERSION,
        compiler_version: VERSION,
        runtime_abi_version: RUNTIME_ABI_VERSION,
        unicode_version: Unicode::VERSION
      }
    end

    def install!(klass, payload)
      rules = payload.fetch(:rules)
      config = payload
      klass.__flexr_reset!
      klass.backend(config.fetch(:backend, :table))
      klass.token_kind(config.fetch(:token_kind, :array))
      klass.encoding(config.fetch(:encoding, Encoding::UTF_8))
      Array(config[:declared_tokens]).each { |token| klass.emits(token) }
      config.fetch(:options, {}).each do |option, value|
        if option == :accel
          klass.accel(value)
        elsif option == :indentation
          klass.indentation(**value)
        elsif value == true
          klass.option(option)
        else
          klass.__flexr_config.options[option] = value
        end
      end
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
      begin
        validate_artifact!(payload[:artifact])
      rescue CompileError => e
        caller = caller_locations.find { |frame| frame.base_label != "install_compiled!" }
        path = caller&.absolute_path || caller&.path
        raise unless path && File.file?(path)

        e.diagnostic.location ||= [0, 0]
        raise CompileError.new(e.message, diagnostic: e.diagnostic, filename: path, byte_pos: 0)
      end
      install!(klass, payload)
      machines = payload.fetch(:compiled).fetch(:machines).transform_values do |machine|
        dfa = load_dfa(machine.fetch(:dfa))
        plans = Automaton::Accel.whole_token_plans(dfa, klass.__flexr_rules) if
          klass.__flexr_config.backend != :firstmatch && klass.__flexr_config.options[:accel] == :strscan
        Automaton::Machine.new(dfa: dfa, state_name: machine.fetch(:state_name).to_sym, whole_tokens: plans)
      end
      compiled = Automaton::CompiledSpec.new(
        machines: machines,
        rules: klass.__flexr_rules,
        states: payload.fetch(:compiled).fetch(:states).map(&:to_sym),
        stats: payload.fetch(:compiled).fetch(:stats),
        diagnostics: payload.fetch(:compiled).fetch(:diagnostics, []).map do |diagnostic|
          Diagnostic.new(**diagnostic.transform_keys(&:to_sym))
        end
      )
      klass.__flexr_set_compiled!(compiled)
      klass.__flexr_mark_generated!
      klass
    end

    def validate_artifact!(artifact)
      return incompatible_artifact!("artifact metadata is missing") unless artifact.is_a?(Hash)

      expected = {
        schema_version: ARTIFACT_SCHEMA_VERSION,
        runtime_abi_version: RUNTIME_ABI_VERSION,
        unicode_version: Unicode::VERSION
      }
      mismatch = expected.find { |name, value| artifact[name] != value }
      compiler_version = artifact[:compiler_version]
      return if mismatch.nil? && compiler_version.is_a?(String) && !compiler_version.empty?

      detail = if mismatch
        name, value = mismatch
        "#{name}=#{artifact[name].inspect} (expected #{value.inspect})"
      else
        "compiler_version=#{compiler_version.inspect}"
      end
      incompatible_artifact!(detail)
    end

    def shareable!(klass)
      unless klass.__flexr_generated? && klass.__flexr_rules.none? { |rule| rule.action.is_a?(Proc) } &&
          klass.__flexr_generated_actions.empty? && klass.__flexr_spec.eof_rules.empty?
        raise ArgumentError, "Ractor sharing requires generated method actions without captured closures or EOF blocks"
      end

      config = klass.__flexr_config
      if config.backend == :firstmatch && klass.__flexr_rules.any? do |rule|
          rule.patterns.any? do |pattern|
            Regexp::Matcher.reference?(pattern, encoding: config.encoding, unicode: config.options[:unicode] == true)
          end
        end
        raise ArgumentError, "Ractor sharing does not support firstmatch reference patterns; use table, direct, or auto"
      end

      original = klass.__flexr_compiled
      rules = original.rules.map do |rule|
        IR::Rule.new(**rule.to_h, trailing_dfa: rule.trailing_dfa && shareable_dfa(rule.trailing_dfa))
      end
      machines = original.machines.transform_values do |machine|
        Automaton::Machine.new(dfa: shareable_dfa(machine.dfa), state_name: machine.state_name,
                                whole_tokens: machine.whole_tokens)
      end
      compiled = Automaton::CompiledSpec.new(**original.to_h, machines: machines, rules: rules)
      Ractor.make_shareable([compiled, klass.__flexr_config, klass.__flexr_states, klass.__flexr_spec.eof_rules,
                             klass.__flexr_generated_actions, klass.__flexr_generated_eof_actions])
      klass.instance_variable_set(:@__flexr_rules, rules)
      klass.__flexr_set_compiled!(compiled)
      klass
    end

    def shareable_dfa(dfa)
      Automaton::DFA.new(transitions: dfa.transitions.map(&:dup), accepts: dfa.accepts, ec: dfa.ec,
                         class_count: dfa.class_count, start: dfa.start, rule_ids: dfa.rule_ids,
                         direct: dfa.direct)
    end

    def incompatible_artifact!(detail)
      diagnostic = Diagnostics.error(
        "FLEXR-E020", "generated artifact is incompatible with this runtime",
        help: "regenerate the lexer with the installed flexr version", note: detail
      )
      raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
    end

    def decode_packed(packed)
      return packed unless packed.is_a?(Hash) && packed[:encoding]&.to_sym == :base64

      {
        base: decode_array(packed.fetch(:base)),
        default: decode_array(packed.fetch(:default), nil_value: -1),
        next: decode_array(packed.fetch(:next), nil_value: -1),
        check: decode_array(packed.fetch(:check), nil_value: -1),
        fallback: packed.key?(:fallback) ? decode_array(packed.fetch(:fallback), nil_value: -1) : nil
      }
    end

    def load_dfa(data)
      Automaton::DFA.new(
        transitions: data[:transitions], accepts: data.fetch(:accepts), ec: data.fetch(:ec),
        class_count: data.fetch(:class_count), start: data.fetch(:start), rule_ids: data.fetch(:rule_ids),
        packed: decode_packed(data[:packed]), direct: data[:direct], state_count: data.fetch(:state_count)
      )
    end

    def decode_array(encoded, nil_value: nil)
      values = encoded.unpack1("m0").unpack("l<*")
      return values unless nil_value

      values.map { |value| value == nil_value ? nil : value }
    end

  end

  module DSL
    def __flexr_add_generated_rule(definition)
      __flexr_mutate! do
        action = definition.fetch(:action)
        @__flexr_rules << IR::Rule.new(
          index: definition.fetch(:index), patterns: Array(definition.fetch(:patterns)),
          trailing: normalize_trailing(definition[:trailing]), action: action,
          states: Array(definition.fetch(:states)).map(&:to_sym),
          bol_only: definition.fetch(:bol_only, false), end_anchor: definition[:end_anchor],
          location: definition[:span] || definition[:location],
          trailing_dfa: definition[:trailing_dfa] && Generated.load_dfa(definition[:trailing_dfa]),
          pattern_conditions: Array(definition[:pattern_conditions]).map do |condition|
            next unless condition

            Automaton::Acceptance.new(rule_index: condition[0], pattern_index: condition[1],
                                      bol_only: condition[2], end_anchor: condition[3])
          end
        )
      end
    rescue CompileError => e
      e.diagnostic.location ||= definition[:span] || definition[:location] if e.diagnostic
      raise
    end
  end
end
