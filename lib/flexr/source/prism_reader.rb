# frozen_string_literal: true

module Flexr
  module Source
      RuleDefinition = Struct.new(
      :index, :patterns, :trailing, :action_source, :action, :states, :bol_only, :end_anchor,
      :pattern_conditions, :bind_action,
      :span, keyword_init: true
    )
      SpecSource = Struct.new(
        :source, :path, :class_name, :rules, :config, :dsl_spans, :first_dsl_offset, :constants,
        :states, :flexr_require_spans, :dsl_edits, keyword_init: true
    )

    class PrismReader
      DSL_NAMES = %i[rule state all_states on_eof emits backend token_kind encoding option accel].freeze

      def initialize(source, path: nil)
        @source = source
        @path = path
        @constants = {}
        @constant_definitions = []
        @resolved_constant_definitions = {}
        @rules = []
        @spans = []
        @edits = []
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

        @lexer_scope = class_name.to_s.delete_prefix("::").split("::").reject(&:empty?)
        collect_constants(prism.value)
        collect_body(klass.body, [:initial])
        require_spans = flexr_require_spans(prism.value)
        first_dsl_offset = @spans.map(&:first).min || class_body_offset(klass)
        @config[:eof_rules] = @eof_rules
        SpecSource.new(source: @source, path: @path, class_name: class_name, rules: @rules,
                       config: @config, dsl_spans: @spans.uniq(&:first),
                       first_dsl_offset: first_dsl_offset, constants: @constants, states: @states,
                       flexr_require_spans: require_spans, dsl_edits: @edits)
      end

      private

      def find_lexer_class(node, namespace = [])
        candidates = lexer_class_candidates(node, namespace)
        dsl_candidates = candidates.select { |candidate, _name| lexer_has_dsl?(candidate.body) }
        unsupported_static!("multiple lexer classes require an explicit selection") if dsl_candidates.length > 1

        dsl_candidates.first || candidates.first
      end

      def lexer_class_candidates(node, namespace = [])
        return [] unless node.respond_to?(:child_nodes)

        kind = node.class.name.split("::").last
        if %w[ClassNode ModuleNode].include?(kind)
          name = source_slice(node.constant_path)
          current_namespace = namespace + name.to_s.split("::")
          own = if kind == "ClassNode" && lexer_superclass?(node)
            [[node, current_namespace.join("::")]]
          else
            []
          end
          return own + node.child_nodes.compact.flat_map { |child| lexer_class_candidates(child, current_namespace) }
        end

        node.child_nodes.compact.flat_map { |child| lexer_class_candidates(child, namespace) }
      end

      def lexer_has_dsl?(node)
        found = false
        each_node(node) do |child|
          found = true if child.class.name.end_with?("CallNode") && child.receiver.nil? && DSL_NAMES.include?(child.name.to_sym)
        end
        found
      end

      def lexer_superclass?(node)
        return false unless node.superclass

        source_slice(node.superclass).delete(" ").sub(/\A::/, "") == "Flexr::Lexer"
      end

      def collect_constants(node, scope: [])
        return unless node

        kind = node.class.name.split("::").last
        if kind == "ProgramNode"
          collect_constants(node.statements, scope: scope)
          return
        end

        if %w[ClassNode ModuleNode].include?(kind)
          nested_scope = scope + namespace_parts(node.constant_path)
          collect_constants(node.body, scope: nested_scope)
          return
        end

        if kind.end_with?("ConstantWriteNode")
          name = qualify_constant(scope, node.name)
          @constant_definitions << [name, node.value, scope.dup, node.location.start_offset]
          return
        end

        if kind == "StatementsNode"
          node.body.each { |child| collect_constants(child, scope: scope) }
          return
        end

        return unless kind == "CallNode" && node.receiver.nil? && %i[state all_states].include?(node.name.to_sym)

        collect_constants(node.block&.body, scope: scope)
      end

      def resolve_constants(before_offset:)
        @constant_definitions.sort_by(&:last).each do |name, value_node, scope, offset|
          next if offset >= before_offset || @resolved_constant_definitions[offset]

          @resolved_constant_definitions[offset] = true
          value = StaticEval.new(@source, constants: @constants, scope: scope).call(value_node)
          @constants[name] = value
        rescue StaticResolutionError
          # Preserve dynamic constants as ordinary Ruby. A later DSL reference
          # still receives FLEXR-E017 instead of seeing a forward value.
        end
      end

      def namespace_parts(node)
        source_slice(node).delete_prefix("::").split("::").reject(&:empty?)
      end

      def qualify_constant(scope, name)
        (scope + [name.to_s]).reject(&:empty?).join("::")
      end

      def collect_body(node, states)
        body = node.respond_to?(:body) ? node.body : []
        Array(body).each do |child|
          resolve_constants(before_offset: child.location.start_offset)
          collect_call(child, states)
        end
      end

      def collect_call(node, states)
        return unless node
        return collect_body(node, states) if node.class.name.end_with?("StatementsNode")
        unless node.class.name.end_with?("CallNode") && node.receiver.nil?
          reject_unhandled_dsl!(node)
          return
        end

        name = node.name.to_sym
        unless DSL_NAMES.include?(name)
          reject_unhandled_dsl!(node)
          return
        end
        record_deletion(node) unless %i[rule state all_states].include?(name)
        case name
        when :rule
          collect_rule(node, states)
        when :state
          collect_state(node, states)
        when :all_states
          collect_all_states(node, states)
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
          @config[:backend] = Configuration.backend!(static(positional(node).first))
        when :token_kind
          @config[:token_kind] = Configuration.token_kind!(static(positional(node).first))
        when :encoding
          @config[:encoding] = static(positional(node).first)
        when :option
          @config[:options] ||= {}
          positional(node).each { |item| @config[:options][Configuration.option!(static(item))] = true }
        when :accel
          @config[:options] ||= {}
          @config[:options][:accel] = Configuration.accelerator!(static(positional(node).first))
        end
      end

      def collect_state(node, parent_states)
        block = node.block
        raise ArgumentError, "state requires a block" unless block

        args = positional(node)
        names = args.map { |argument| static(argument, scope: @lexer_scope).to_sym }
        names = parent_states if node.name.to_sym == :all_states
        raise ArgumentError, "state requires a name" if names.empty?

        validate_keywords!(node, %i[inclusive])
        inclusive = keyword(node, :inclusive) ? static(keyword(node, :inclusive), scope: @lexer_scope) : false
        names.each do |name|
          existing = @states[name]
          raise ArgumentError, "state #{name.inspect} already declared with inclusive: #{existing[:inclusive]}" if
            existing && existing[:inclusive] != inclusive
          @states[name] ||= { inclusive: inclusive }
        end
        record_state_wrapper(node, block)
        active_states = parent_states == [:initial] ? names : (parent_states + names).uniq
        collect_body(block.body, active_states)
      end

      def collect_all_states(node, parent_states)
        block = node.block
        raise ArgumentError, "all_states requires a block" unless block

        validate_keywords!(node, [])
        unsupported_static!("all_states does not accept arguments") unless positional(node).empty?
        record_state_wrapper(node, block)
        collect_body(block.body, (parent_states + @states.keys).uniq)
      end

      def collect_rule(node, states)
        values = positional(node)
        patterns = static(values.first, scope: @lexer_scope)
        patterns = [patterns] unless patterns.is_a?(Array)
        unless (@allow_dynamic && patterns.any?(&:nil?)) || patterns.all? { |pattern| pattern.is_a?(::Regexp) || pattern.is_a?(String) }
          diagnostic = Diagnostics.error("FLEXR-E018", "rule pattern must be a Regexp, String, or Array")
          raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
        end
        options = keywords(node)
        validate_keywords!(node, %i[skip emit followed_by])
        action_source = node.block && source_slice(node.block)
        if action_source&.match?(/\breject\b/)
          diagnostic = Diagnostics.error(
            "FLEXR-E013", "reject is not supported by flexr",
            help: "use a state transition and less(n) to express the fallback"
          )
          raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
        end
        block_action = if action_source
          action_source.start_with?("do") ? "proc #{action_source}" : "proc#{action_source}"
        end
        skip = options.key?(:skip) ? static(options[:skip], scope: @lexer_scope) : false
        emit = options.key?(:emit) ? static(options[:emit], scope: @lexer_scope) : nil
        action = ActionResolver.resolve(
          skip: skip, emit: emit, block: block_action, default: "proc { emit(nil, text) }"
        )
        bind_action = !block_action.nil? && action.equal?(block_action)
        rule_index = @rules.length
        record_rule_edit(node, rule_index, bind_action ? block_action : nil)
        @rules << RuleDefinition.new(
          index: rule_index, patterns: patterns,
          trailing: options[:followed_by] && static(options[:followed_by], scope: @lexer_scope),
          action_source: action_source, action: action, states: states.dup,
          bol_only: false, end_anchor: nil,
          span: [node.location.start_offset, node.location.end_offset], bind_action: bind_action
        )
      end

      def static(node, scope: @lexer_scope)
        StaticEval.new(@source, constants: @constants, scope: scope).call(node)
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

      def validate_keywords!(node, allowed)
        unknown = keywords(node).keys - allowed
        unsupported_static!("unknown keyword #{unknown.first.inspect} for #{node.name}") unless unknown.empty?
      end

      def record_deletion(node)
        span = [node.location.start_offset, node.location.end_offset]
        @spans << span
        @edits << [*span, ""]
      end

      def record_rule_edit(node, rule_index, block_action)
        span = [node.location.start_offset, node.location.end_offset]
        replacement = block_action ? "__flexr_bind_generated_action(#{rule_index}, #{block_action})" : ""
        @spans << span
        @edits << [*span, replacement]
      end

      def record_state_wrapper(node, block)
        body = block.body
        return record_deletion(node) unless body

        body_start = Source::Passthrough.line_start_offset(@source, body.location.start_offset)
        opening = [node.location.start_offset, body_start]
        closing = [body.location.end_offset, node.location.end_offset]
        opening_source = @source.byteslice(block.location.start_offset...body_start)
        closing_source = @source.byteslice(body.location.end_offset...block.location.end_offset)
        @spans.push(opening, closing)
        @edits << [*opening, "(::Kernel.proc #{opening_source}"]
        @edits << [*closing, "#{closing_source}).call"]
      end

      def reject_unhandled_dsl!(node)
        each_node_including_self(node) do |child|
          next unless child.class.name.end_with?("CallNode")
          if %i[send public_send].include?(child.name.to_sym)
            dynamic_name = dynamically_dispatched_dsl(child)
            unsupported_static!("dynamic dispatch of #{dynamic_name} is not statically supported") if dynamic_name
          end
          next unless DSL_NAMES.include?(child.name.to_sym)
          next unless child.receiver.nil? || child.receiver.class.name.end_with?("SelfNode")

          unsupported_static!("#{child.name} must be a direct receiverless statement in a lexer or state body")
        end
      end

      def dynamically_dispatched_dsl(node)
        first_argument = Array(node.arguments&.arguments).first
        return unless first_argument && first_argument.class.name.end_with?("SymbolNode")

        name = first_argument.unescaped.to_sym
        name if DSL_NAMES.include?(name)
      end

      def unsupported_static!(reason)
        diagnostic = Diagnostics.error(
          "FLEXR-E017", "DSL structure is not statically supported",
          help: "move the DSL call to the lexer or state body, or use --eval", note: reason
        )
        raise StaticResolutionError.new(diagnostic.message, diagnostic: diagnostic)
      end

      def each_node(node, &block)
        return unless node

        node.child_nodes.each do |child|
          block.call(child)
          each_node(child, &block)
        end
      end

      def flexr_require_spans(node)
        spans = []
        each_node_including_self(node) do |child|
          next unless child.class.name.end_with?("CallNode")
          next unless child.receiver.nil? && child.name.to_sym == :require

          arguments = Array(child.arguments&.arguments)
          next unless arguments.one?

          argument = arguments.first
          next unless argument.class.name.end_with?("StringNode") && argument.unescaped == "flexr"

          spans << [child.location.start_offset, child.location.end_offset]
        end
        spans
      end

      def each_node_including_self(node, &block)
        return unless node

        block.call(node)
        node.child_nodes.compact.each { |child| each_node_including_self(child, &block) }
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
