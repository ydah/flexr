# frozen_string_literal: true

require "ruby_lsp/addon"
require "flexr/cli"

RubyLsp::Addon.depend_on_ruby_lsp!("~> 0.26.11")

module RubyLsp
  module Flexr
    class Analysis
      def diagnostics(source)
        return @diagnostics if @source == source

        @channels = {}
        diagnostics = begin
          parsed = ::Flexr::Source::PrismReader.new(source).read
          parsed.rules.each { |rule| @channels[rule.span.first] = rule.channel if rule.channel }
          compiled = ::Flexr::CLI.compile(parsed, overrides: { warn_level: :all })
          compiled.diagnostics.reject { |diagnostic| diagnostic.code == "FLEXR-W016" }
        rescue ::Flexr::Error => e
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
        @analysis.diagnostics(source).map do |diagnostic|
          first, last = diagnostic.location || [0, 0]
          severity = { error: Constant::DiagnosticSeverity::ERROR, warning: Constant::DiagnosticSeverity::WARNING,
                       info: Constant::DiagnosticSeverity::INFORMATION }.fetch(diagnostic.severity)
          Interface::Diagnostic.new(
            range: Interface::Range.new(start: position(source, first), end: position(source, last)),
            message: @analysis.message(diagnostic), code: diagnostic.code, severity: severity, source: "flexr"
          )
        end
      end

      private

      def position(source, offset)
        prefix = source.byteslice(0, [offset, source.bytesize].min)
        line = prefix.count("\n")
        column = prefix.byteslice(((prefix.b.rindex("\n") || -1) + 1)..).delete_suffix("\r")
        character = case @encoding
        when Encoding::UTF_8 then column.bytesize
        when Encoding::UTF_16LE then column.encode(Encoding::UTF_16LE).bytesize / 2
        else column.length
        end
        Interface::Position.new(line: line, character: character)
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
        sections << "```text\n#{text}\n```" unless text.empty?
        @builder.push(sections.join("\n\n"), category: :documentation) unless sections.empty?
      end
    end

    class Addon < ::RubyLsp::Addon
      def activate(global_state, _message_queue)
        @analysis = Analysis.new
        global_state.register_formatter("flexr", Diagnostics.new(@analysis, global_state.encoding))
      end

      def deactivate
        @analysis = nil
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
    end
  end
end
