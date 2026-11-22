# frozen_string_literal: true

module Flexr
  module Rules
    def self.extended(rule_set)
      raise ArgumentError, "extend Flexr::Rules on a module" if rule_set.is_a?(Class)
    end

    def rule(...) = __flexr_rule_template.rule(...)
    def pattern(...) = __flexr_rule_template.pattern(...)
    def upto(...) = __flexr_rule_template.upto(...)

    def __flexr_rule_entries
      __flexr_rule_template.__flexr_rules.dup
    end

    private

    def __flexr_rule_template
      @__flexr_rule_template ||= Class.new(Lexer)
    end

    module Use
      def use(rule_set)
        raise ArgumentError, "use expects a module extended with Flexr::Rules" unless rule_set.is_a?(Module) && rule_set.is_a?(Rules)

        __flexr_mutate! do
          states = @__flexr_state_stack.empty? ? [:initial] : @__flexr_state_stack
          first_index = @__flexr_rules.length
          additions = rule_set.__flexr_rule_entries.map.with_index do |entry, index|
            IR::Rule.new(**entry.to_h, index: first_index + index, patterns: entry.patterns.dup, states: states.dup)
          end
          @__flexr_rules.concat(additions)
          include Runtime::Channels if additions.any?(&:channel)
        end
        nil
      end

      private

      def __flexr_bind_rule_set(rule_set, count, bindings)
        entries = rule_set.__flexr_rule_entries if rule_set.is_a?(Rules)
        raise CompileError, "rule set declarations changed after generation" unless entries&.length == count

        bindings.each do |rule_index, entry_index|
          __flexr_bind_generated_action(rule_index, entries.fetch(entry_index).action)
        end
      end
    end
  end

  Lexer.extend(Rules::Use)
end
