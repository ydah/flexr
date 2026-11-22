# frozen_string_literal: true

module Flexr
  module Source
    module Fixes
      Edit = Data.define(:code, :range, :replacement)

      module_function

      def capture_edits(parsed, diagnostics)
        return [] if parsed.config[:backend] == :firstmatch

        spans = diagnostics.filter_map { |item| item.location if item.code == "FLEXR-W013" }.to_h { |span| [span, true] }
        return [] if spans.empty?

        nodes = [::Prism.parse(parsed.source).value]
        edits = []
        until nodes.empty?
          node = nodes.pop
          location = node.location
          if node.is_a?(::Prism::CallNode) && node.name == :rule && spans[[location.start_offset, location.end_offset]]
            arguments = node.arguments.arguments.grep(::Prism::RegularExpressionNode)
            arguments.each { |argument| edits.concat(capture_literal_edits(argument, parsed.config.fetch(:encoding))) }
          else
            nodes.concat(node.compact_child_nodes)
          end
        end
        edits.sort_by { |edit| edit.range.begin }
      end

      def apply(source, edits)
        result = source.b
        edits.reverse_each { |edit| result[edit.range] = edit.replacement }
        result.force_encoding(source.encoding)
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
      private_class_method :capture_literal_edits
    end
  end
end
