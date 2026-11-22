# frozen_string_literal: true

require "ruby_lsp/addon"
require "flexr/cli"
require "flexr/source/fixes"
require_relative "ranges"
require_relative "navigation"

RubyLsp::Addon.depend_on_ruby_lsp!("~> 0.26.11")

module RubyLsp
  module Flexr
    class Analysis
      def diagnostics(source)
        return @diagnostics if @source == source

        @channels = {}
        @edits = []
        diagnostics = begin
          parsed = ::Flexr::Source::PrismReader.new(source).read
          parsed.rules.each { |rule| @channels[rule.span.first] = rule.channel if rule.channel }
          compiled = ::Flexr::CLI.compile(parsed, overrides: { warn_level: :all })
          @edits = ::Flexr::Source::Fixes.edits(parsed, compiled)
          diagnostics = compiled.diagnostics.reject { |diagnostic| diagnostic.code == "FLEXR-W016" }
          tables = parsed.config.dig(:options, :keyword_tables)
          diagnostics.concat(::Flexr::Automaton::KeywordTables.grouping_suggestions(compiled, tables)) if @edits.any? { |edit| edit.code == "FLEXR-I003" }
          diagnostics
        rescue ::Flexr::Error => e
          @edits = ::Flexr::Source::Fixes.regexp_edits(parsed, e.diagnostic)
          e.diagnostic ? [e.diagnostic] : []
        rescue ArgumentError => e
          [::Flexr::Diagnostics.error("FLEXR-E017", e.message, location: [0, 0])]
        end
        @source = source.dup.freeze
        @diagnostics = diagnostics
      end

      def channel_at(offset)
        @channels[offset]
      end

      def edits(diagnostic)
        return [] unless diagnostic.location

        first, last = diagnostic.location
        @edits.select { |edit| edit.code == diagnostic.code && edit.range.begin.between?(first, last) }
      end

      def message(diagnostic)
        [diagnostic.message, diagnostic.note,
         ("help: #{diagnostic.help}" if diagnostic.help)].compact.join("\n\n")
      end
    end

    class Diagnostics
      def initialize(analysis, encoding)
        @analysis = analysis
        @encoding = encoding
      end

      def run_diagnostic(uri, document)
        return [] unless uri.path&.end_with?(".flexr.rb")

        source = document.source
        ranges = Ranges.new(source, @encoding)
        @analysis.diagnostics(source).map do |diagnostic|
          first, last = diagnostic.location || [0, 0]
          severity = { error: Constant::DiagnosticSeverity::ERROR, warning: Constant::DiagnosticSeverity::WARNING,
                       info: Constant::DiagnosticSeverity::INFORMATION }.fetch(diagnostic.severity)
          Interface::Diagnostic.new(
            range: ranges.range(first, last),
            message: @analysis.message(diagnostic), code: diagnostic.code, severity: severity, source: "flexr",
            data: code_action_data(uri, document, diagnostic, ranges)
          )
        end
      end

      private

      def code_action_data(uri, document, diagnostic, ranges)
        edits = @analysis.edits(diagnostic)
        return if edits.empty?

        changes = edits.map do |edit|
          Interface::TextEdit.new(range: ranges.range(edit.range.begin, edit.range.end), new_text: edit.replacement)
        end
        versioned_document = Interface::OptionalVersionedTextDocumentIdentifier.new(uri: uri.to_s, version: document.version)
        document_edit = Interface::TextDocumentEdit.new(text_document: versioned_document, edits: changes)
        action = Interface::CodeAction.new(
          title: ::Flexr::Source::Fixes::TITLES.fetch(diagnostic.code), kind: Constant::CodeActionKind::QUICK_FIX,
          edit: Interface::WorkspaceEdit.new(document_changes: [document_edit])
        )
        { code_actions: [action] }
      end
    end

    class Hover
      def initialize(builder, analysis, dispatcher)
        @builder = builder
        @analysis = analysis
        dispatcher.register(self, :on_call_node_enter)
      end

      def on_call_node_enter(node)
        return unless %i[rule keywords].include?(node.name) && node.receiver.nil?

        source = node.location.source_lines.join
        diagnostics = @analysis.diagnostics(source).select do |diagnostic|
          diagnostic.location &&
            (node.location.start_offset...node.location.end_offset).cover?(diagnostic.location.first)
        end
        text = diagnostics.map { |diagnostic| "#{diagnostic.code}: #{@analysis.message(diagnostic)}" }.join("\n\n")
        sections = []
        sections << "Keyword table. Exact spellings select a token type after a matching emit: rule wins." if node.name == :keywords
        channel = @analysis.channel_at(node.location.start_offset)
        if channel
          sections << "Channel `#{channel.inspect}` preserves trivia. " \
            "Read it with `tokens(channels: :all)` or `leading_trivia` on structured tokens."
        end
        hint = priority_hint(node) if node.name == :rule
        sections << hint if hint
        sections << "```text\n#{text}\n```" unless text.empty?
        @builder.push(sections.join("\n\n"), category: :documentation) unless sections.empty?
      end

      private

      def priority_hint(node)
        keywords = Array(node.arguments&.arguments).grep(Prism::KeywordHashNode).flat_map(&:elements)
        pair = keywords.grep(Prism::AssocNode).find do |option|
          option.key.is_a?(Prism::SymbolNode) && option.key.value == "priority"
        end
        return unless pair&.value.is_a?(Prism::IntegerNode)

        "priority #{pair.value.value} breaks equal-length matches. Higher priority wins, then source order."
      end
    end

    class Addon < ::RubyLsp::Addon
      def activate(global_state, _message_queue)
        @analysis = Analysis.new
        @encoding = global_state.encoding
        @outline_builders = ObjectSpace::WeakKeyMap.new
        global_state.register_formatter("flexr", Diagnostics.new(@analysis, @encoding))
      end

      def deactivate
        @analysis = nil
        @outline_builders = nil
      end

      def name
        "flexr"
      end

      def version
        ::Flexr::VERSION
      end

      def create_hover_listener(response_builder, _node_context, dispatcher)
        Hover.new(response_builder, @analysis, dispatcher)
      end

      def create_definition_listener(builder, uri, context, _dispatcher)
        return unless specification_uri?(uri) && context.node && context.call_node && !context.surrounding_method

        source = context.node.location.source_lines.join
        specification = Navigation.specification_at(context.node, source)
        locations = specification&.state_definitions(context.node, context.call_node)
        return if locations.nil? || locations.empty?

        ranges = Ranges.new(source, @encoding)
        locations.each do |location|
          builder << Interface::Location.new(uri: uri.to_s, range: ranges.location(location))
        end
      end

      def create_completion_listener(builder, context, _dispatcher, uri)
        return unless specification_uri?(uri) && context.node && context.call_node && !context.surrounding_method

        source = context.node.location.source_lines.join
        specification = Navigation.specification_at(context.node, source)
        site = specification&.completion_site(
          context.node, context.call_node, source: source, recover_utf8: @encoding == Encoding::UTF_8
        )
        return unless site

        range = Ranges.new(source, @encoding).location(site.location)
        specification.token_names(excluding: site).each do |name|
          next unless name.start_with?(site.prefix)

          label = name.to_sym.inspect
          edit = Interface::TextEdit.new(range: range, new_text: label)
          builder << Interface::CompletionItem.new(label: label, kind: Constant::CompletionItemKind::ENUM_MEMBER, text_edit: edit)
        end
      end

      def create_document_symbol_listener(builder, dispatcher)
        @outline_builders[dispatcher] = builder
      end

      def create_code_lens_listener(_builder, uri, dispatcher)
        # Ruby LSP uses one dispatcher for these requests and passes the URI to the code lens hook.
        builder = @outline_builders.delete(dispatcher)
        Navigation::Outline.new(builder, dispatcher, @encoding) if builder && specification_uri?(uri)
      end

      private

      def specification_uri?(uri)
        uri.path&.end_with?(".flexr.rb")
      end
    end
  end
end
