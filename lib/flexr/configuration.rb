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

    def encoding!(value)
      encoding = value.is_a?(Encoding) ? value : Encoding.find(value.to_s)
      return encoding if [Encoding::UTF_8, Encoding::BINARY].include?(encoding)

      diagnostic = Diagnostics.error("FLEXR-E011", "flexr supports UTF-8 and BINARY only")
      raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
    end

    def option!(value)
      validated_symbol!(value, BOOLEAN_OPTIONS, :option)
    end

    def rule_priority!(value)
      return value if value.is_a?(Integer)

      diagnostic = Diagnostics.error("FLEXR-E018", "rule priority must be an Integer")
      raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
    end

    def rule_channel!(value)
      return value if value.is_a?(Symbol) && value != :all

      diagnostic = Diagnostics.error("FLEXR-E018", "rule channel must be a Symbol other than :all")
      raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
    end

    def rule_emits!(value, emit: nil, location: nil)
      return if value.nil?

      types = value.is_a?(Symbol) ? [value] : value
      return types.uniq.freeze if !emit && types.is_a?(Array) && !types.empty? && types.all?(Symbol)

      message = emit ? "emits: cannot be combined with emit:" : "emits: requires a Symbol or a nonempty Array of Symbols"
      diagnostic = Diagnostics.error("FLEXR-E018", message, location: location)
      raise CompileError.new(message, diagnostic: diagnostic)
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
