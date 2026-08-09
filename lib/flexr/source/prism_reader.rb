# frozen_string_literal: true

module Flexr
  module Source
      RuleDefinition = Struct.new(
      :index, :patterns, :trailing, :action_source, :action, :states, :bol_only, :end_anchor,
      :pattern_conditions,
      :span, keyword_init: true
    )
      SpecSource = Struct.new(
        :source, :path, :class_name, :rules, :config, :dsl_spans, :first_dsl_offset, :constants,
        :states, keyword_init: true
    )

    class PrismReader
      DSL_NAMES = %i[rule state all_states on_eof emits backend token_kind encoding option accel].freeze

      def initialize(source, path: nil)
        @source = source
        @path = path
        @constants = {}
        @rules = []
        @spans = []
        @states = { initial: { inclusive: true } }
        @eof_rules = {}
        @config = { backend: :table, token_kind: :array, encoding: Encoding::UTF_8, declared_tokens: [] }
      end

      def read(allow_dynamic: false)
        @allow_dynamic = allow_dynamic
        prism = begin
          require "prism"
          Prism.parse(@source)
        rescue LoadError => e
          diagnostic = Diagnostics.error("FLEXR-E019", "Prism is required for source generation", note: e.message)
          raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
        end
        unless prism.errors.empty?
          error = prism.errors.first
          diagnostic = Diagnostics.error("FLEXR-E010", error.message)
          raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
        end

        klass, class_name = find_lexer_class(prism.value)
        raise CompileError, "no class inheriting from Flexr::Lexer found" unless klass

        collect_constants(klass.body)
        collect_body(klass.body, [:initial])
        first_dsl_offset = @spans.map(&:first).min || class_body_offset(klass)
        @config[:eof_rules] = @eof_rules
        SpecSource.new(source: @source, path: @path, class_name: class_name, rules: @rules,
                       config: @config, dsl_spans: @spans.uniq(&:first),
                       first_dsl_offset: first_dsl_offset, constants: @constants, states: @states)
      end

      private

      def find_lexer_class(node, namespace = [])
        return nil unless node.respond_to?(:child_nodes)

        kind = node.class.name.split("::").last
        if %w[ClassNode ModuleNode].include?(kind)
          name = source_slice(node.constant_path)
          current_namespace = namespace + name.to_s.split("::")
          return [node, current_namespace.join("::")] if kind == "ClassNode" && lexer_superclass?(node)
          node.child_nodes.compact.each do |child|
            found = find_lexer_class(child, current_namespace)
            return found if found
          end
          return nil
        end

        node.child_nodes.compact.each do |child|
          found = find_lexer_class(child, namespace)
          return found if found
        end
        nil
      end

      def lexer_superclass?(node)
        return false unless node.superclass

        source_slice(node.superclass).delete(" ") == "Flexr::Lexer"
      end

      def collect_constants(node)
        each_node(node) do |child|
          next unless child.class.name.end_with?("ConstantWriteNode")

          @constants[child.name] = static(child.value)
        end
      end

      def collect_body(node, states)
        body = node.respond_to?(:body) ? node.body : []
        Array(body).each do |child|
          collect_call(child, states)
        end
      end

      def collect_call(node, states)
        return unless node
        return collect_body(node, states) if node.class.name.end_with?("StatementsNode")
        return unless node.class.name.end_with?("CallNode")
        return if node.receiver

        name = node.name.to_sym
        return unless DSL_NAMES.include?(name)
        @spans << [node.location.start_offset, node.location.end_offset]
        case name
        when :rule
          collect_rule(node, states)
        when :state
          collect_state(node, states)
        when :all_states
          collect_state(node, @states.keys)
        when :on_eof
          action_source = node.block && source_slice(node.block)
          action = if action_source
            action_source.start_with?("do") ? "proc #{action_source}" : "proc#{action_source}"
          end
          @eof_rules[states.last.to_sym] = action if action
        when :emits
          values = positional(node).map { |item| static(item) }.compact.flatten
          @config[:declared_tokens].concat(values.map(&:to_sym))
        when :backend
          @config[:backend] = static(positional(node).first).to_sym
        when :token_kind
          @config[:token_kind] = static(positional(node).first).to_sym
        when :encoding
          @config[:encoding] = static(positional(node).first)
        when :option
          @config[:options] ||= {}
          positional(node).each { |item| @config[:options][static(item).to_sym] = true }
        when :accel
          @config[:options] ||= {}
          @config[:options][:accel] = static(positional(node).first).to_sym
        end
      end

      def collect_state(node, parent_states)
        args = positional(node)
        names = args.map { |argument| static(argument).to_sym }
        names = parent_states if node.name.to_sym == :all_states
        inclusive = keyword(node, :inclusive) ? static(keyword(node, :inclusive)) : false
        names.each { |name| @states[name] = { inclusive: inclusive } }
        block = node.block
        collect_body(block&.body, names)
      end

      def collect_rule(node, states)
        values = positional(node)
        patterns = static(values.first)
        patterns = [patterns] unless patterns.is_a?(Array)
        unless (@allow_dynamic && patterns.any?(&:nil?)) || patterns.all? { |pattern| pattern.is_a?(::Regexp) || pattern.is_a?(String) }
          diagnostic = Diagnostics.error("FLEXR-E018", "rule pattern must be a Regexp, String, or Array")
          raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
        end
        options = keywords(node)
        action_source = node.block && source_slice(node.block)
        action = if action_source
          action_source.start_with?("do") ? "proc #{action_source}" : "proc#{action_source}"
        end
        @rules << RuleDefinition.new(
          index: @rules.length, patterns: patterns, trailing: options[:followed_by] && static(options[:followed_by]),
          action_source: action_source, action: action || action_for(options), states: states.dup,
          bol_only: false, end_anchor: nil,
          span: [node.location.start_offset, node.location.end_offset]
        )
      end

      def action_for(options)
        return :skip if options[:skip] && static(options[:skip])
        return [:emit, static(options[:emit]).to_sym] if options[:emit]

        "proc { emit(nil, text) }"
      end

      def static(node)
        StaticEval.new(@source, constants: @constants).call(node)
      rescue StaticResolutionError
        raise unless @allow_dynamic

        nil
      end

      def positional(node)
        Array(node.arguments&.arguments).reject { |argument| argument.class.name.end_with?("KeywordHashNode") }
      end

      def keywords(node)
        hash = Array(node.arguments&.arguments).find { |argument| argument.class.name.end_with?("KeywordHashNode") }
        Array(hash&.elements).to_h { |assoc| [static(assoc.key).to_sym, assoc.value] }
      end

      def keyword(node, key)
        keywords(node)[key]
      end

      def each_node(node, &block)
        return unless node

        node.child_nodes.each do |child|
          block.call(child)
          each_node(child, &block)
        end
      end

      def source_slice(node)
        return "" unless node

        location = node.respond_to?(:location) ? node.location : node
        @source.byteslice(location.start_offset...location.end_offset)
      end

      def class_body_offset(node)
        return node.body.location.start_offset if node.body

        ending = node.location.end_offset
        return ending - 3 if @source.byteslice(ending - 3, 3) == "end"

        ending
      end
    end
  end
end
