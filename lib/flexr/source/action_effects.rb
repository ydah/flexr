# frozen_string_literal: true

module Flexr
  module Source
    module ActionEffects
      Effect = Data.define(:action, :token, :channel, :state_operations)
      STATE_OPERATIONS = {
        push: :push, push_state: :push, pop: :pop, pop_state: :pop,
        begin_state: :begin_state, :state= => :begin_state
      }.freeze

      module_function

      def steps(block)
        return unless block.is_a?(Prism::BlockNode) && block.parameters.nil?
        return [] unless block.body
        return unless block.body.is_a?(Prism::StatementsNode)

        actions = block.body.body.map { |statement| step(statement) }
        actions if actions.all?
      end

      def step(call)
        return unless call.is_a?(Prism::CallNode) && call.block.nil?
        return unless call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode)

        arguments = Array(call.arguments&.arguments)
        case call.name
        when :emit
          return unless (1..2).cover?(arguments.length) && token_literal?(arguments.first)
          return if arguments.length == 2 && !safe_value?(arguments.last)

          token = arguments.first.unescaped if arguments.first.is_a?(Prism::SymbolNode)
          [:emit, token&.to_sym] if token.nil? || token.valid_encoding?
        when :skip
          [:skip] if arguments.empty?
        else
          operation = STATE_OPERATIONS[call.name]
          return unless operation
          return [:pop] if operation == :pop && arguments.empty?
          return if operation == :pop || arguments.length != 1

          argument = arguments.first
          return unless state_literal?(argument)

          name = argument.unescaped
          [operation, name.to_sym] if name.valid_encoding?
        end
      end

      def token_literal?(node)
        node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::NilNode)
      end

      def state_literal?(node)
        node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
      end

      def safe_value?(node)
        return true if state_literal?(node) || node.is_a?(Prism::NilNode) || node.is_a?(Prism::IntegerNode) ||
                       node.is_a?(Prism::FloatNode) || node.is_a?(Prism::TrueNode) || node.is_a?(Prism::FalseNode)

        node.is_a?(Prism::CallNode) && node.name == :text && node.receiver.nil? &&
          node.arguments.nil? && node.block.nil?
      end

      def for_rule(rule)
        if rule.bind_action
          return unless rule.action_steps

          emission = rule.action_steps.reverse_each.find { |step| %i[emit skip].include?(step.first) }
          operations = rule.action_steps.reject { |step| %i[emit skip].include?(step.first) }
          effect(emission || [:skip], rule.channel, operations)
        elsif rule.action == :skip
          effect([:skip], nil, [])
        elsif rule.action.is_a?(Array)
          effect(rule.action, rule.channel, [])
        else
          effect([:emit, nil], rule.channel, [])
        end
      end

      def effect(emission, channel, operations)
        action, token = emission
        Effect.new(action: action, token: token, channel: (channel if action == :emit),
                   state_operations: operations.map(&:freeze).freeze)
      end
    end
  end
end
