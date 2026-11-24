# frozen_string_literal: true

module Flexr
  module Runtime
    module ParserContexts
      Plan = Data.define(:terminals, :expected, :accepts) unless const_defined?(:Plan, false)
      private_constant :Plan

      def self.install(klass, data)
        config = klass.__flexr_config
        indentation = config.options[:indentation]
        machines = if indentation || config.options[:keyword_tables] || config.backend == :firstmatch
          {}
        else
          klass.__flexr_compiled.machines
        end
        masks = data.fetch(:rule_masks)
        plans = data.fetch(:terminal_sets).each_with_index.map do |terminals, set|
          expected = terminals.to_h { |terminal| [terminal, true] }
          expected[indentation.fetch(:newline)] = true if indentation
          mask = masks.fetch(set)
          accepts = machines.transform_values do |machine|
            machine.dfa.accepts.map do |row|
              next row if row.empty?

              filtered = row.select { |acceptance| mask[acceptance.rule_index] == 1 }
              filtered.size == row.size ? row : filtered.freeze
            end.freeze
          end
          Plan.new(terminals: terminals.freeze, expected: expected.freeze, accepts: accepts.freeze)
        end
        contexts = data.fetch(:states).map { |set| plans.fetch(set) }.freeze
        klass.instance_variable_set(:@__flexr_parser_contexts, contexts)
        klass.prepend(self)
      end

      def initialize(...)
        super
        @__flexr_parser_contexts = self.class.instance_variable_get(:@__flexr_parser_contexts)
      end

      def next_token(expect: nil, parser_state: nil)
        previous = @__flexr_parser_context
        if parser_state.nil?
          @__flexr_parser_context = nil
          return expect.nil? ? super() : super(expect: expect)
        end

        raise ArgumentError, "parser_state: cannot be combined with expect:" unless expect.nil?

        contexts = @__flexr_parser_contexts
        raise ArgumentError, "unknown parser state #{parser_state.inspect}" unless
          contexts && parser_state.is_a?(Integer) && parser_state >= 0 && parser_state < contexts.length

        plan = contexts[parser_state]
        @__flexr_parser_context = plan
        @generated_scanner ? super() : super(expect: plan.terminals)
      ensure
        @__flexr_parser_context = previous
      end

      private

      def __flexr_parser_fast_input?
        return @__flexr_parser_fast_input if @__flexr_parser_fast_buffer.equal?(@buffer)
        return false if token_limit_required? || scan_steps_guarded? || (@accel_mode != :auto && @accel_mode != :none)

        source = @buffer.stable_source
        @__flexr_parser_fast_input = source.instance_of?(String) && source.frozen? && source.singleton_methods.empty? &&
          (!utf8_input? || source.ascii_only?)
        @__flexr_parser_fast_buffer = @buffer
        @__flexr_parser_fast_input
      end

      def handle_unmatched_byte(expected = nil)
        super(expected || @__flexr_parser_context&.expected)
      end

      def clear_input_scanners
        @__flexr_parser_fast_buffer = nil
        super
      end
    end
  end
end
