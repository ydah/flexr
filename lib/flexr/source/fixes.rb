# frozen_string_literal: true

module Flexr
  module Source
    module Fixes
      Edit = Data.define(:code, :range, :replacement)
      TITLES = {
        "FLEXR-W013" => "Use non-capturing groups",
        "FLEXR-I003" => "Group literal rules into a keyword table",
        "FLEXR-W001" => "Give the shadowed literal higher priority",
        "FLEXR-E014" => "Stop at the first closing quote with an absence group"
      }.freeze

      module_function

      def edits(parsed, compiled)
        return [] if parsed.config[:backend] == :firstmatch

        groups = keyword_edits(parsed, compiled)
        priority = priority_edits(parsed, compiled, groups)
        (capture_edits(parsed, compiled.diagnostics) + groups + priority).sort_by { |edit| edit.range.begin }
      end

      def capture_edits(parsed, diagnostics)
        spans = diagnostics.filter_map { |item| item.location if item.code == "FLEXR-W013" }
        rule_calls(parsed, spans).flat_map do |node|
          node.arguments.arguments.grep(::Prism::RegularExpressionNode).flat_map do |argument|
            capture_literal_edits(argument, parsed.config.fetch(:encoding))
          end
        end
      end

      def rule_calls(parsed, spans)
        return [] if spans.empty?

        nodes = [::Prism.parse(parsed.source).value]
        calls = []
        until nodes.empty?
          node = nodes.pop
          location = node.location
          if node.is_a?(::Prism::CallNode) && node.name == :rule && spans.include?([location.start_offset, location.end_offset])
            calls << node
          else
            nodes.concat(node.compact_child_nodes)
          end
        end
        calls
      end

      def keyword_edits(parsed, compiled)
        tables = parsed.config.dig(:options, :keyword_tables)
        Automaton::KeywordTables.grouping_candidates(compiled, tables).filter_map do |literals, rule|
          spans = [*literals, rule].map(&:location)
          next if spans.any?(&:nil?)
          next unless spans.each_cons(2).all? do |(_, last), (first, _)|
            first >= last && parsed.source.byteslice(last...first).match?(/\A[ \t]*\r?\n[ \t]*\z/)
          end

          spellings = literals.map { |literal| literal.patterns.first }.uniq
          Edit.new("FLEXR-I003", spans.first.first...spans[-2].last, "keywords #{spellings.inspect}, among: #{rule.action[1].inspect}")
        end
      end

      def apply(source, edits)
        result = source.b
        edits.reverse_each { |edit| result[edit.range] = edit.replacement }
        result.force_encoding(source.encoding)
      end

      def priority_edits(parsed, compiled, group_edits)
        spans = compiled.diagnostics.filter_map { |item| item.location if item.code == "FLEXR-W001" }
        return [] if spans.empty? || compiled.rules.any?(&:trailing)

        acceptances = compiled.machines.values.flat_map { |machine| machine.dfa.accepts }.reject(&:empty?)
        return [] if acceptances.any? { |items| items.any? { |item| item.bol_only || item.end_anchor } }

        ranked = acceptances.map { |items| items.map(&:rule_index) }
        rules = compiled.rules.to_h { |rule| [rule.location, rule] }
        priority = compiled.rules.map(&:priority).max + 1
        rule_calls(parsed, spans).sort_by { |node| node.location.start_offset }.filter_map do |node|
          span = [node.location.start_offset, node.location.end_offset]
          rule = rules.fetch(span)
          next unless rule.emit? && !rule.channel && rule.patterns.one? && rule.patterns.first.is_a?(String)
          next if group_edits.any? { |edit| edit.range.cover?(span.first) }

          next unless ranked.any? { |ids| ids.include?(rule.index) }

          proposed = ranked.map { |ids| ids.include?(rule.index) ? [rule.index, *(ids - [rule.index])] : ids }
          next unless (ranked.map(&:first) - proposed.map(&:first)).empty?

          edit = priority_edit(node, priority)
          ranked = proposed
          edit
        end
      end

      def priority_edit(node, priority)
        arguments = node.arguments
        options = arguments.arguments.last
        entries = options.is_a?(::Prism::KeywordHashNode) ? options.elements : []
        existing = entries.find { |entry| entry.key.is_a?(::Prism::SymbolNode) && entry.key.unescaped == "priority" }
        if existing
          location = existing.value.location
          Edit.new("FLEXR-W001", location.start_offset...location.end_offset, priority.to_s)
        else
          position = arguments.location.end_offset
          Edit.new("FLEXR-W001", position...position, ", priority: #{priority}")
        end
      end

      def regexp_edits(parsed, diagnostic)
        return [] unless parsed && diagnostic&.code == "FLEXR-E014" && parsed.config[:backend] != :firstmatch

        rule_calls(parsed, [diagnostic.location]).flat_map do |node|
          node.arguments.arguments.grep(::Prism::RegularExpressionNode).filter_map do |argument|
            literal = argument.content_loc
            quote = /\A(["'])\.\*\?\1\z/.match(literal.slice)&.[](1)
            next unless quote

            forbidden = argument.options.anybits?(::Regexp::MULTILINE) ? quote : "[#{quote}\\n]"
            Edit.new("FLEXR-E014", literal.start_offset...literal.end_offset, "#{quote}(?~#{forbidden})#{quote}")
          end
        end
      end

      def capture_literal_edits(node, encoding)
        literal = node.content_loc
        source = literal.slice
        return [] unless source == node.unescaped

        offsets = []
        Regexp::Parser.new(source, options: node.options, encoding: encoding, capture_offsets: offsets).parse
        offsets.map do |offset|
          position = literal.start_offset + offset + 1
          Edit.new("FLEXR-W013", position...position, "?:")
        end
      rescue CompileError
        []
      end
      private_class_method :capture_literal_edits, :rule_calls, :priority_edit
    end
  end
end
