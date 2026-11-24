# frozen_string_literal: true

module Flexr
  module Runtime
    Boundary = Data.define(:position, :line, :column, :state, :stack, :dfa_start, :bol, :left_context, :layout) do
      def self.standard_lexer?(lexer_class)
        return false unless lexer_class.method(:new).owner == Class

        generated = lexer_class.__flexr_generated?
        lexer_class.ancestors.take_while { |ancestor| ancestor != Lexer }.all? do |ancestor|
          next true if ancestor.name&.start_with?("Flexr::Runtime::") ||
            (defined?(Keywords::Emission) && ancestor == Keywords::Emission)

          methods = ancestor.instance_methods(false) + ancestor.private_instance_methods(false)
          methods.all? do |name|
            generated && ancestor == lexer_class && (name == :scan_one || name.start_with?("__flexr_generated_"))
          end
        end
      end

      def converges?(old, delta:)
        position == old.position + delta && position.zero? == old.position.zero? &&
          state == old.state && stack == old.stack && dfa_start == old.dfa_start &&
          bol == old.bol && left_context == old.left_context && layout == old.layout
      end
    end
  end
end
