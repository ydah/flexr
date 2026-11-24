# frozen_string_literal: true

module Flexr
  module Automaton
    WholeToken = Struct.new(:regexp, :rule_index, keyword_init: true)

    module Accel
      module_function

      def whole_token_plans(dfa, rules)
        return if dfa.starts || rules.any?(&:trailing) || !dfa.accepts[dfa.start].empty?
        return if rules.any?(&:capture_patterns)
        return if defined?(Pattern) && rules.any? { |rule| rule.patterns.any?(Pattern) }
        return if dfa.accepts.any? { |acceptances| acceptances.any? { |item| item.bol_only || item.end_anchor } }

        plans = Array.new(256)
        memo = {}
        token_edges(dfa, dfa.start).each do |destination, bytes|
          next if bytes.any? { |byte| byte >= 128 }
          expression, winners = token_expression(dfa, destination, memo, [])
          next unless expression && winners.one?

          source = "[#{bytes_to_source(bytes)}]#{expression}"
          next if source.bytesize > 4096

          regexp = ::Regexp.new(source).freeze
          plan = WholeToken.new(regexp: regexp, rule_index: winners.first).freeze
          bytes.each { |byte| plans[byte] = plan }
        end
        plans.freeze unless plans.compact.empty?
      end

      def token_expression(dfa, state, memo, ancestors)
        return memo[state] if memo.key?(state)
        # shortcut: cap expansion at 32 states/4 KiB, revisit for measured DFA fallback bottlenecks.
        return [nil, []] if ancestors.include?(state) || ancestors.length >= 32

        edges = token_edges(dfa, state)
        return memo[state] = [nil, []] if edges.values.any? { |bytes| bytes.any? { |byte| byte >= 128 } }

        loops = edges.delete(state)
        winner = dfa.accepts[state].first&.rule_index
        winners = winner ? [winner] : []
        alternatives = edges.map do |destination, bytes|
          tail, accepted = token_expression(dfa, destination, memo, ancestors + [state])
          return memo[state] = [nil, []] unless tail

          winners |= accepted
          return memo[state] = [nil, []] if winners.length > 1

          "[#{bytes_to_source(bytes)}]#{tail}"
        end
        return memo[state] = [nil, []] if alternatives.empty? && winner.nil?

        tail = alternatives.empty? ? "" : "(?:#{alternatives.join('|')})#{'?' unless winner.nil?}"
        expression = "#{"[#{bytes_to_source(loops)}]*" if loops}#{tail}"
        return memo[state] = [nil, []] if expression.bytesize > 4096

        memo[state] = [expression, winners]
      end

      def token_edges(dfa, state)
        (0..255).each_with_object({}) do |byte, edges|
          destination = dfa.transition(state, byte)
          (edges[destination] ||= []) << byte if destination
        end
      end
    end
  end
end
