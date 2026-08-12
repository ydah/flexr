# frozen_string_literal: true

module Flexr
  module Generated
    ARTIFACT_SCHEMA_VERSION = 1
    RUNTIME_ABI_VERSION = 1

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
      validate_artifact!(payload[:artifact])
      install!(klass, payload)
      machines = payload.fetch(:compiled).fetch(:machines).transform_values do |machine|
        dfa_data = machine.fetch(:dfa)
        packed = decode_packed(dfa_data[:packed])
        dfa = Automaton::DFA.new(
          transitions: dfa_data[:transitions] || inflate_packed(packed, dfa_data.fetch(:state_count),
                                                                 dfa_data.fetch(:class_count)),
          accepts: dfa_data.fetch(:accepts),
          ec: dfa_data.fetch(:ec),
          class_count: dfa_data.fetch(:class_count),
          start: dfa_data.fetch(:start),
          rule_ids: dfa_data.fetch(:rule_ids),
          packed: packed,
          direct: dfa_data[:direct]
        )
        Automaton::Machine.new(dfa: dfa, state_name: machine.fetch(:state_name).to_sym)
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

    def decode_array(encoded, nil_value: nil)
      values = encoded.unpack1("m0").unpack("l<*")
      return values unless nil_value

      values.map { |value| value == nil_value ? nil : value }
    end

    def inflate_packed(packed, state_count, class_count)
      return nil unless packed

      Array.new(state_count) do |state|
        Array.new(class_count) do |class_id|
          cursor = state
          loop do
            index = packed.fetch(:base).fetch(cursor) + class_id
            break packed.fetch(:next).fetch(index) if packed.fetch(:check)[index] == cursor

            fallback = packed[:fallback]&.fetch(cursor)
            break packed.fetch(:default).fetch(cursor) unless fallback

            cursor = fallback
          end
        end
      end
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
          pattern_conditions: Array(definition[:pattern_conditions]).map do |condition|
            next unless condition

            Automaton::Acceptance.new(rule_index: condition[0], pattern_index: condition[1],
                                      bol_only: condition[2], end_anchor: condition[3])
          end
        )
      end
    end
  end
end
