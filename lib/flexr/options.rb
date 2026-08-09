# frozen_string_literal: true

module Flexr
  Options = Struct.new(
    :backend, :token_kind, :accel, :standalone, :eval_mode, :table_compression,
    :table_format, :max_dfa_states, :warn_level, :warn_as_error, :color, :format, :overrides,
    keyword_init: true
  ) do
    def self.default
      new(backend: :table, token_kind: :array, accel: :auto, standalone: false,
          eval_mode: false, table_compression: :rows, table_format: :literal,
          max_dfa_states: 100_000, warn_level: :default, warn_as_error: false,
          color: :auto, format: :human, overrides: {})
    end

    def set(name, value)
      self[name] = value
      self.overrides ||= {}
      overrides[name] = value
    end

    def validate!
      validate_value!(backend, %i[table direct firstmatch auto], :backend)
      validate_value!(token_kind, %i[array struct yield], :token_kind)
      validate_value!(accel, %i[auto strscan regexp none], :accel)
      validate_value!(table_compression, %i[none rows full], :table_compression)
      validate_value!(table_format, %i[literal packed], :table_format)
      validate_value!(warn_level, %i[all default none], :warn_level)
      validate_value!(color, %i[auto always never], :color)
      validate_value!(format, %i[human json], :format)
      raise ArgumentError, "unsupported max_dfa_states: #{max_dfa_states.inspect}" unless max_dfa_states.is_a?(Integer) && max_dfa_states.positive?
      self
    end

    def generator_options
      (overrides || {}).merge(warn_as_error: warn_as_error, color: color)
    end

    private

    def validate_value!(value, allowed, name)
      return if allowed.include?(value)

      raise ArgumentError, "unsupported #{name}: #{value.inspect}"
    end
  end
end
