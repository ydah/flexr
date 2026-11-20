# frozen_string_literal: true

module Flexr
  module Migration
    module_function

    def diagnostics(parsed)
      require "prism"
      source = parsed.source
      result = [Diagnostics.info("FLEXR-I002", "v2.0 requires Ruby 3.4+; regenerate all generated lexers after upgrading",
                                 help: "review docs/migration-v2.md and consumer code; static checks cannot find all record mutations or initialization calls")]
      visit = lambda do |node|
        return unless node

        if node.is_a?(Prism::CallNode) && parsed.dsl_spans.include?([node.location.start_offset, node.location.end_offset]) &&
            node.receiver.nil? && node.name == :token_kind &&
            node.arguments&.arguments&.first.is_a?(Prism::SymbolNode) &&
            node.arguments.arguments.first.unescaped == "struct"
          result << Diagnostics.warning(
            "FLEXR-W020", "structured tokens and locations become immutable Data records in v2.0",
            location: [node.location.start_offset, node.location.end_offset],
            help: "replace field assignments with record.with(...); review consumer code and Struct-specific APIs"
          )
        end
        node.compact_child_nodes.each { |child| visit.call(child) }
      end
      visit.call(Prism.parse(source).value)
      result
    end
  end
end
