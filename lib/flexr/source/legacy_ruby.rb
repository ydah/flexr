# frozen_string_literal: true

module Flexr
  module Source
    class LegacyRuby
      TARGETS = %w[2.5 3.0].freeze
      REMOVED_METHODS = %i[incremental parallel_tokens shareable!].freeze
      FORWARDED = "*__flexr_args, **__flexr_keywords, &__flexr_block"
      PROPERTY_ESCAPE = /(?:\A|[^\\])(?:\\\\)*\\[pP]\{/

      attr_reader :version

      def initialize(version)
        raise ArgumentError, "unsupported Ruby target #{version.inspect}; choose 2.5 or 3.0" unless TARGETS.include?(version)

        @version = version
        if version == "2.5"
          require "parser/ruby25"
          @parser_class = ::Parser::Ruby25
        else
          require "parser/ruby30"
          @parser_class = ::Parser::Ruby30
        end
      end

      def validate_source!(parsed, backend:)
        root = ::Prism.parse(parsed.source).value
        each_node(root) do |node|
          case node.type
          when :constant_read_node
            reject!("Ractor requires a modern runtime", node.location) if node.name == :Ractor
          when :constant_path_node
            reject!("Ractor requires a modern runtime", node.location) if node.parent.nil? && node.name == :Ractor
          when :call_node
            reject_removed_call!(node, parsed.class_name)
            reject!("the firstmatch backend requires a modern runtime", node.location) if node.name == :backend && backend == :firstmatch
          when :regular_expression_node
            reject!("Unicode property escapes require a modern regexp engine", node.content_loc) if PROPERTY_ESCAPE.match?(node.unescaped)
          when :interpolated_regular_expression_node
            node.parts.grep(::Prism::StringNode).each do |part|
              reject!("Unicode property escapes require a modern regexp engine", part.location) if PROPERTY_ESCAPE.match?(part.unescaped)
            end
          end
        end
        raise_error!("the firstmatch backend requires a modern runtime", [parsed.first_dsl_offset, parsed.first_dsl_offset]) if backend == :firstmatch

        parsed.rules.each do |rule|
          next unless (rule.patterns + [rule.trailing]).any? { |pattern| unicode_property?(pattern) }

          raise_error!("Unicode property escapes require a modern regexp engine", rule.span)
        end
        validate_syntax!(parsed.source, path: parsed.path)
      end

      def validate_syntax!(source, path:, generated: false)
        parser = @parser_class.new
        parser.diagnostics.ignore_warnings = true
        failure = nil
        parser.diagnostics.consumer = ->(diagnostic) { failure ||= diagnostic }
        parser.parse(::Parser::Source::Buffer.new(path || "(lexer)", source: source))
        syntax_error!(source, failure, generated) if failure
      rescue ::Parser::SyntaxError
        syntax_error!(source, failure, generated)
      end

      def artifact(source, path:)
        guard = /^raise LoadError, "flexr requires Ruby (\d+\.\d+) or newer" if RUBY_VERSION < "\1"$/
        raise_error!("generated standalone version guard is missing", nil) unless guard.match?(source)

        lowered = source.sub(guard, "# target-ruby: #{version}\nraise LoadError, \"flexr requires Ruby #{version} or newer\" if RUBY_VERSION < \"#{version}\"")
        validate_syntax!(lowered, path: path, generated: true)
        lowered
      end

      def lower(source)
        edits = collect_edits(::Prism.parse(source).value)
        output = source.b.dup
        edits.each_with_index.sort_by { |(first, _last, _text), index| [first, index] }.reverse_each do |(first, last, text), _index|
          output[first...last] = text.b
        end
        output.force_encoding(source.encoding)
      end

      private

      def each_node(node, &)
        node.compact_child_nodes.each { |child| each_node(child, &) }
        yield node
      end

      def reject_removed_call!(node, lexer_name)
        receiver = node.receiver.location.slice.delete_prefix("::") if node.receiver
        case node.name
        when :shareable!
          return unless %w[Flexr::Generated Generated].include?(receiver)
        when :incremental, :parallel_tokens
          full_name = lexer_name.delete_prefix("::")
          return unless [nil, "self", full_name, full_name.split("::").last].include?(receiver)
        else
          return
        end

        reject!("#{node.name} requires a modern runtime", node.message_loc || node.location)
      end

      def collect_edits(node)
        return replace(node.location, "") if node.type == :def_node && REMOVED_METHODS.include?(node.name)

        node.compact_child_nodes.flat_map { |child| collect_edits(child) } + Array(edits_for(node))
      end

      def unicode_property?(pattern)
        case pattern
        when ::Regexp then PROPERTY_ESCAPE.match?(pattern.source)
        when Pattern
          return PROPERTY_ESCAPE.match?(pattern.operands.first) if pattern.operation == :regexp

          pattern.operands.any? { |operand| unicode_property?(operand) }
        end
      end

      def edits_for(node)
        case node.type
        when :def_node then method_edits(node)
        when :call_node then call_edits(node)
        when :block_parameter_node then replace(node.location, "&__flexr_block") unless node.name
        when :block_argument_node then replace(node.location, "&__flexr_block") unless node.expression
        when :keyword_rest_parameter_node then replace(node.location, "**__flexr_keywords") unless node.name
        when :assoc_splat_node then replace(node.location, "**__flexr_keywords") unless node.value
        when :rest_parameter_node then replace(node.location, "*__flexr_args") unless node.name
        when :splat_node then replace(node.location, "*__flexr_args") unless node.expression
        when :forwarding_parameter_node, :forwarding_arguments_node then replace(node.location, FORWARDED)
        when :implicit_node then insert(node.location.end_offset, " #{node.value.name}")
        when :range_node then insert(node.location.end_offset, "-1") if version == "2.5" && node.right.nil?
        end
      end

      def method_edits(node)
        if node.name == :shareable && node.location.slice.include?("Ractor.shareable?")
          replace(node.body.location, "Generated.shareable_dfa(dfa)")
        elsif node.equal_loc
          replace(node.equal_loc, ";") + insert(node.location.end_offset, "; end")
        end
      end

      def call_edits(node)
        if node.name == :define && %w[Data ::Data].include?(node.receiver&.location&.slice)
          replace(node.receiver.location, "::Flexr::LegacyRubyRecord")
        elsif node.name == :byteindex && node.receiver&.location&.slice == "source"
          # The generated byteindex path requires ASCII-8BIT, where index returns byte offsets.
          replace(node.message_loc, "index")
        elsif node.name == :replay_capture_data && node.receiver.nil?
          replace(node.location, "::Flexr::LegacyRubyMatch.wrap(replay_capture_data)")
        elsif %i[byteoffset named_captures].include?(node.name) && node.receiver&.location&.slice == "match"
          replace(node.receiver.location, "::Flexr::LegacyRubyMatch.wrap(match)")
        elsif version == "2.5" && node.name == :new && node.receiver&.location&.slice == "Fiber" && node.arguments&.location&.slice == "blocking: true"
          replace(node.receiver.location, "::Flexr::LegacyRubyFiber") + replace(node.message_loc, "start") + replace(node.arguments.location, "")
        elsif version == "2.5" && node.block
          suffix = { filter_map: ".select(&:itself)", to_h: ".to_h" }[node.name]
          return unless suffix

          replace(node.message_loc, "map") + insert(node.location.end_offset, suffix)
        end
      end

      def replace(location, text)
        [[location.start_offset, location.end_offset, text]]
      end

      def insert(offset, text)
        [[offset, offset, text]]
      end

      def reject!(message, location)
        raise_error!(message, [location.start_offset, location.end_offset])
      end

      def syntax_error!(source, diagnostic, generated)
        location = diagnostic&.location
        first = location ? source[0...location.begin_pos].bytesize : 0
        last = location ? source[0...location.end_pos].bytesize : first
        first -= 1 if first.positive? && source.getbyte(first - 1) == 0x26
        description = generated ? "generated code uses unsupported syntax" : "source uses unsupported syntax"
        raise_error!(description, generated ? nil : [first, last], note: diagnostic&.message)
      end

      def raise_error!(message, location, note: nil)
        diagnostic = Diagnostics.error("FLEXR-E035", "Ruby #{version}: #{message}", location: location, note: note)
        raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
      end
    end
  end
end
