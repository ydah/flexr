# frozen_string_literal: true

module Flexr
  module IR
    Rule = Struct.new(
      :index, :patterns, :trailing, :action, :states, :bol_only, :end_anchor, :location,
      :pattern_conditions,
      keyword_init: true
    ) do
      def skip?
        action == :skip
      end

      def emit?
        action.is_a?(Array) && action.first == :emit
      end
    end

    State = Struct.new(:name, :inclusive, :id, keyword_init: true)

    Spec = Struct.new(
      :class_name, :superclass, :backend, :token_kind, :encoding, :options,
      :declared_tokens, :states, :rules, :eof_rules, :verbatim,
      keyword_init: true
    ) do
      def initial_state
        :initial
      end
    end

    Config = Struct.new(
      :backend, :token_kind, :encoding, :options, :declared_tokens, :states,
      keyword_init: true
    )
  end
end
