# frozen_string_literal: true

require_relative "../source/semantic_diff"

module Flexr
  module Grammar
    module ContextAmbiguity
      module_function

      def diagnostics(input, rows, paths, limit: 100_000)
        contexts = rows.each_with_index.select { |terminals, id| terminals.size >= 2 && paths.fetch(id) }
        return [] if contexts.empty?

        reason = unsupported_reason(input)
        return [Diagnostics.warning("FLEXR-W025", "parser-state ambiguity check is incomplete", note: reason)] if reason

        sides = input.compiled.states.to_h { |state| [state, input.side(state)] }
        checked = {}
        contexts.flat_map do |terminals, id|
          sides.filter_map do |state, side|
            result = checked[[state, terminals]] ||= Automaton::TokenDiff.context_ambiguity(
              side, terminals: terminals, encoding: input.encoding, limit: limit
            )
            diagnostic(result, id, state, paths.fetch(id))
          end
        end
      end

      def unsupported_reason(input)
        return "backend :firstmatch selects by rule order" if input.backend == :firstmatch
        return "indentation can change rule eligibility" if input.options[:indentation]

        nil
      end

      def diagnostic(result, id, state, path)
        return if result.status == :equal

        context = "parser state #{id} in lexer state #{state.inspect}"
        prefix = [*path, "•"].join(" ")
        help = "parser path: #{prefix}"
        return Diagnostics.warning("FLEXR-W025", "#{context}: ambiguity check is incomplete", help: help, note: result.reason) if
          result.status == :inconclusive

        left, right = [result.left.effect.token, result.right.effect.token].sort
        Diagnostics.warning(
          "FLEXR-W024", "#{context} accepts both #{left.inspect} and #{right.inspect} at the same winning length",
          help: help, note: "example input: #{result.input.inspect} (byte offset #{result.offset})"
        )
      end

      private_class_method :unsupported_reason, :diagnostic
    end
  end
end
