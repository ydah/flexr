# frozen_string_literal: true

module RubyLsp
  module Flexr
    module Navigation
      module_function

      def lexer_class?(node)
        return false unless node.is_a?(Prism::ClassNode) && node.superclass

        node.superclass.slice.delete(" ").delete_prefix("::") == "Flexr::Lexer"
      end

      def specification_at(reference, source)
        offset = reference.location.start_offset
        program = Prism.parse(source).value
        pending = [program]
        scope = nil
        until pending.empty?
          node = pending.pop
          next unless (node.location.start_offset...node.location.end_offset).cover?(offset)

          scope = node if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::SingletonClassNode)
          pending.concat(node.compact_child_nodes)
        end
        Specification.new(scope) if lexer_class?(scope)
      end

      class Specification
        CompletionSite = Data.define(:location, :prefix)
        STATE_CHANGES = %i[begin_state push push_state state=].freeze
        BLOCKS = %i[state all_states].freeze
        DECLARATIONS = %i[rule state all_states emits keywords on_eof].freeze

        def initialize(klass)
          @klass = klass
          @declarations = declarations(klass.body).flat_map { |call| [call, *nested_declarations(call)] }
        end

        def state_definitions(reference, call)
          return [] unless action_call?(call) && STATE_CHANGES.include?(call.name)
          return [] unless same_location?(arguments(call).first, reference)

          name = literal_name(reference)
          return [] unless name

          @declarations.select { |declaration| declaration.name == :state && declaration.block }.flat_map do |declaration|
            arguments(declaration).filter_map { |node| node.location if literal_name(node) == name }
          end
        end

        def completion_site(node, call, source:, recover_utf8:)
          return unless node.equal?(call)

          if call.name == :emit && action_call?(call)
            return symbol_site(arguments(call).first) if arguments(call).drop(1).all? { |argument| individually_located?(argument) }

            return
          end
          return unless %i[rule on_eof].include?(call.name) && @declarations.any? { |declaration| same_location?(declaration, call) }

          symbol_site(keyword_value(call, :emit)) || recovered_emit_site(call, source, recover_utf8)
        end

        def token_names(excluding:)
          @declarations.flat_map do |call|
            case call.name
            when :emits
              arguments(call).flat_map { |argument| literal_names(argument) }
            when :rule
              symbol = keyword_value(call, :emit)
              same_location?(symbol, excluding) ? [] : [literal_name(symbol)]
            when :keywords
              [literal_name(keyword_value(call, :among)), *keyword_token_names(arguments(call).first)]
            else
              []
            end
          end.compact.uniq.sort
        end

        def outline(ranges)
          symbols(@klass.body, ranges)
        end

        private

        def symbol_site(node)
          CompletionSite.new(node.location, node.unescaped) if node.is_a?(Prism::SymbolNode)
        end

        def individually_located?(argument)
          argument.is_a?(Prism::CallNode) || argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode)
        end

        def recovered_emit_site(declaration, source, recover_utf8)
          body = declaration.block&.body
          return unless body.is_a?(Prism::StatementsNode)

          emit = body.body.reverse.find { |statement| !statement.is_a?(Prism::MissingNode) }
          return unless emit.is_a?(Prism::CallNode) && emit.name == :emit && action_call?(emit)

          if emit.arguments
            return symbol_site(arguments(emit).first) if recover_utf8 && arguments(emit).one? && !emit.location.slice_lines.ascii_only?

            return
          end

          # Without parentheses Prism leaves the trailing colon outside the recovered call.
          offset = emit.message_loc.end_offset
          suffix = source.byteslice(offset..)
          colon = /\A[ \t]+(:)(?=[ \t]*(?:[}#\r\n]|\z))/.match(suffix)
          return unless colon

          location = emit.message_loc.copy(start_offset: offset + colon.begin(1), length: 1)
          CompletionSite.new(location, "")
        end

        def declarations(body)
          return [] unless body.is_a?(Prism::StatementsNode)

          body.body.select { |call| call.is_a?(Prism::CallNode) && !call.receiver && DECLARATIONS.include?(call.name) }
        end

        def nested_declarations(call)
          return [] unless BLOCKS.include?(call.name) && call.block.is_a?(Prism::BlockNode)

          declarations(call.block.body).flat_map { |nested| [nested, *nested_declarations(nested)] }
        end

        def action_call?(call)
          return false unless call && (!call.receiver || call.receiver.is_a?(Prism::SelfNode))

          @declarations.any? do |declaration|
            block = declaration.block
            %i[rule on_eof].include?(declaration.name) && block.is_a?(Prism::BlockNode) &&
              (block.location.start_offset...block.location.end_offset).cover?(call.location.start_offset)
          end
        end

        def same_location?(node, other)
          node && node.location.start_offset == other.location.start_offset && node.location.end_offset == other.location.end_offset
        end

        def arguments(call)
          call.arguments&.arguments || []
        end

        def keyword_value(call, key)
          options = arguments(call).last
          return unless options.is_a?(Prism::KeywordHashNode)

          pair = options.elements.find { |item| item.is_a?(Prism::AssocNode) && literal_name(item.key) == key.to_s }
          pair&.value
        end

        def literal_name(node)
          node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
        end

        def literal_names(node)
          return node.elements.flat_map { |item| literal_names(item) } if node.is_a?(Prism::ArrayNode)

          [literal_name(node)]
        end

        def keyword_token_names(node)
          case node
          when Prism::ArrayNode
            literal_names(node).compact.map(&:upcase)
          when Prism::HashNode
            node.elements.grep(Prism::AssocNode).map { |pair| literal_name(pair.value) }
          else
            []
          end
        end

        def symbols(body, ranges)
          declarations(body).filter_map do |call|
            case call.name
            when :rule
              pattern = arguments(call).first
              label = pattern&.slice.to_s.lines.first.to_s.strip
              name = label.empty? ? "rule" : "rule #{label}"
              document_symbol(call, name, Constant::SymbolKind::METHOD, pattern&.location, [], ranges)
            when :state, :all_states
              next unless call.block.is_a?(Prism::BlockNode)

              names = arguments(call).grep_v(Prism::KeywordHashNode)
              name = [call.name, *names.map(&:slice)].join(" ")
              selection = names.one? ? names.first.location : call.message_loc
              children = symbols(call.block.body, ranges)
              document_symbol(call, name, Constant::SymbolKind::NAMESPACE, selection, children, ranges)
            end
          end
        end

        def document_symbol(call, name, kind, selection, children, ranges)
          Interface::DocumentSymbol.new(
            name: name, kind: kind, range: ranges.location(call.location),
            selection_range: ranges.location(selection || call.message_loc), children: children
          )
        end
      end

      class Outline
        def initialize(builder, dispatcher, encoding)
          @builder = builder
          @encoding = encoding
          @lexer_symbols = {}
          dispatcher.register(self, :on_class_node_enter, :on_class_node_leave)
        end

        def on_class_node_enter(node)
          return unless Navigation.lexer_class?(node)

          ranges = Ranges.new(node.location.source_lines.join, @encoding)
          symbol = @builder.last
          symbol.children.concat(Specification.new(node).outline(ranges))
          @lexer_symbols[node] = symbol
        end

        def on_class_node_leave(node)
          @lexer_symbols.delete(node)&.children&.sort_by! do |symbol|
            position = symbol.range.start
            [position.line, position.character]
          end
        end
      end
    end
  end
end
