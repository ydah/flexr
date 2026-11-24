# frozen_string_literal: true

module Flexr
  module DSL
    module ShortestStates
      UNSPECIFIED = Object.new.freeze unless const_defined?(:UNSPECIFIED, false)
      private_constant :UNSPECIFIED

      def self.validate!(match)
        return if %i[shortest longest].include?(match)

        raise ArgumentError, "unsupported state match: #{match.inspect}"
      end

      def self.agree!(name, match, shortest)
        previous = shortest.include?(name) ? :shortest : :longest
        return if match == previous

        raise ArgumentError, "state #{name.inspect} already declared with match: #{previous.inspect}"
      end

      def __flexr_reset!
        @__flexr_initial_match_declared = false
        super
      end

      def state(*names, inclusive: false, match: UNSPECIFIED, &block)
        return super(*names, inclusive: inclusive, &block) if match.equal?(UNSPECIFIED) || names.empty? || !block

        ShortestStates.validate!(match)
        __flexr_mutate! do
          names = names.map(&:to_sym)
          options = @__flexr_config.options
          shortest = Array(options[:shortest_states])
          names.each do |name|
            next if name == :initial && !@__flexr_initial_match_declared
            next unless @__flexr_states.key?(name)

            ShortestStates.agree!(name, match, shortest)
          end
          super(*names, inclusive: inclusive) do
            @__flexr_initial_match_declared = true if names.include?(:initial)
            options[:shortest_states] = (shortest | names).freeze if match == :shortest
            class_eval(&block)
          end
        end
      end
    end

    prepend ShortestStates
  end
end
