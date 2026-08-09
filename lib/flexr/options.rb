# frozen_string_literal: true

module Flexr
  Options = Struct.new(
    :backend, :token_kind, :accel, :standalone, :eval_mode, :table_compression,
    :table_format, :max_dfa_states, :warn_level, :warn_as_error, :color, :format,
    keyword_init: true
  ) do
    def self.default
      new(backend: :table, token_kind: :array, accel: :auto, standalone: false,
          eval_mode: false, table_compression: :none, table_format: :literal,
          max_dfa_states: 100_000, warn_level: :default, warn_as_error: false,
          color: :auto, format: :human)
    end
  end
end
