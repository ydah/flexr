# frozen_string_literal: true

module Flexr
  module Configuration
    BACKENDS = %i[table direct firstmatch auto].freeze
    TOKEN_KINDS = %i[array struct yield].freeze
    ACCELERATORS = %i[auto strscan regexp none].freeze
    BOOLEAN_OPTIONS = %i[unicode eager_columns allow_empty_match experimental standalone].freeze

    module_function

    def backend!(value)
      validated_symbol!(value, BACKENDS, :backend)
    end

    def token_kind!(value)
      validated_symbol!(value, TOKEN_KINDS, :token_kind)
    end

    def accelerator!(value)
      validated_symbol!(value, ACCELERATORS, :accel)
    end

    def option!(value)
      validated_symbol!(value, BOOLEAN_OPTIONS, :option)
    end

    def validated_symbol!(value, allowed, name)
      symbol = value.to_sym
      return symbol if allowed.include?(symbol)

      raise ArgumentError, "unsupported #{name}: #{value.inspect}"
    rescue NoMethodError
      raise ArgumentError, "unsupported #{name}: #{value.inspect}"
    end
  end
end
