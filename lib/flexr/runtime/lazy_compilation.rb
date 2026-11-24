# frozen_string_literal: true

module Flexr
  module Runtime
    module LazyCompilation
      def __flexr_compile_runtime!
        return __flexr_runtime_compiled if __flexr_runtime_compiled

        config = @__flexr_config
        return super unless %i[table direct].include?(config.backend)
        return super if Flexr.cache_dir || config.options.key?(:max_dfa_states)
        return super if config.options.key?(:accel) && config.options[:accel] != :none

        @__flexr_compile_mutex.synchronize do
          __flexr_runtime_compiled || begin
            compiled = Automaton::Compiler.new(__flexr_spec).compile(lazy: true)
            return super unless Lookbehind.graphs(compiled).empty?

            include Keywords::Emission if config.options[:keyword_tables]
            freeze_specification!
            @__flexr_runtime_compiled = freeze_compiled!(compiled)
          end
        end
      end

      def __flexr_runtime_compiled
        @__flexr_compiled || @__flexr_runtime_compiled
      end

      def compile!
        return @__flexr_compiled if @__flexr_compiled

        @__flexr_compile_mutex.synchronize do
          return super unless @__flexr_runtime_compiled

          @__flexr_compiled ||= begin
            spec = __flexr_spec
            spec.rules = spec.rules.map { |rule| rule.dup.tap { |copy| copy.capture_patterns = nil } }
            compiled = Automaton::Compiler.new(spec).compile
            freeze_rules!(compiled.rules)
            freeze_compiled!(compiled)
          end
        end
      end
    end
  end

  DSL.prepend(Runtime::LazyCompilation)
end
