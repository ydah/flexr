# frozen_string_literal: true

require_relative "action_effects"

module Flexr
  module Source
      RuleDefinition = Struct.new(
      :index, :patterns, :trailing, :action_source, :action, :states, :bol_only, :end_anchor,
      :pattern_conditions, :bind_action, :reads_locals, :channel, :dynamic_channel, :priority, :emit_shorthand, :emits,
      :span, :action_steps, keyword_init: true
    )
      SpecSource = Struct.new(
        :source, :path, :class_name, :rules, :config, :dsl_spans, :first_dsl_offset, :constants,
      :states, :flexr_require_spans, :dsl_edits, :uses_patterns, :uses_rule_sets, :uses_input_stack, :uses_delegation,
      :uses_dynamic_delimiters, keyword_init: true
    )

    class PrismReader
      DSL_NAMES = %i[rule use state all_states on_eof emits keywords indentation backend token_kind encoding option accel].freeze

      def initialize(source, path: nil)
        @source = source
        @path = path
        @constants = {}
        @constant_definitions = []
        @namespaces = Hash.new { |entries, name| entries[name] = [] }
        @rule_set_modules = {}
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
          diagnostic = Diagnostics.error("FLEXR-E019", "Prism is required for source generation",
                                         location: [0, 0], help: "install the generator dependency with gem install prism",
                                         note: e.message)
          raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
        end
        unless prism.errors.empty?
          error = prism.errors.first
          diagnostic = Diagnostics.error("FLEXR-E010", error.message,
                                         location: [error.location.start_offset, error.location.end_offset])
          raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
        end

        klass, class_name = find_lexer_class(prism.value)
        raise CompileError, "no class inheriting from Flexr::Lexer found" unless klass

        @states[:initial][:location] = [klass.location.start_offset, klass.location.end_offset]
        @lexer_scope = class_name.to_s.delete_prefix("::").split("::").reject(&:empty?)
        @lexer_offset = klass.location.start_offset
        collect_constants(prism.value)
        collect_rule_namespaces(prism.value)
        collect_body(klass.body, [])
        require_spans = flexr_require_spans(prism.value)
        first_dsl_offset = @spans.map(&:first).min || class_body_offset(klass)
        @config[:eof_rules] = @eof_rules
        uses_patterns = false
        uses_rule_sets = false
        uses_delegation = false
        uses_input_stack = false
        uses_dynamic_delimiters = false
        each_node(prism.value) do |node|
          next unless node.is_a?(::Prism::CallNode)

          uses_patterns ||= %i[pattern upto].include?(node.name)
          uses_rule_sets ||= rule_set_extension?(node)
          uses_delegation ||= node.name == :delegate
          uses_input_stack ||= node.name == :push_input
          uses_dynamic_delimiters ||= %i[scan_until scan_until_line].include?(node.name)
        end
        SpecSource.new(source: @source, path: @path, class_name: class_name, rules: @rules,
                       config: @config, dsl_spans: @spans.uniq(&:first),
                       first_dsl_offset: first_dsl_offset, constants: @constants, states: @states,
                       flexr_require_spans: require_spans, dsl_edits: @edits, uses_patterns: uses_patterns,
                       uses_rule_sets: uses_rule_sets,
                       uses_input_stack: uses_input_stack, uses_delegation: uses_delegation,
                       uses_dynamic_delimiters: uses_dynamic_delimiters)
      end

      private

      def find_lexer_class(node, namespace = [])
        candidates = lexer_class_candidates(node, namespace)
        dsl_candidates = candidates.select { |candidate, _name| lexer_has_dsl?(candidate.body) }
        unsupported_static!("multiple lexer classes require an explicit selection", dsl_candidates[1].first) if dsl_candidates.length > 1

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

      def resolve_constants(before_offset:, constants: @constants, resolved: @resolved_constant_definitions)
        @constant_definitions.sort_by(&:last).each do |name, value_node, scope, offset|
          next if offset >= before_offset || resolved[offset]

          resolved[offset] = true
          value = StaticEval.new(@source, constants: constants, scope: scope).call(value_node)
          constants[name] = value
        rescue StaticResolutionError
          # Preserve dynamic constants as ordinary Ruby. A later DSL reference
          # still receives FLEXR-E017 instead of seeing a forward value.
        end
        constants
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
        return if @rule_set_modules.key?(node.location.start_offset)
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
        record_deletion(node) unless %i[rule use state all_states on_eof].include?(name)
        case name
        when :rule
          collect_rule(node, states.empty? ? [:initial] : states)
        when :use
          collect_use(node, states.empty? ? [:initial] : states)
        when :state
          collect_state(node, states)
        when :all_states
          collect_all_states(node, states)
        when :on_eof
          action_source = node.block && source_slice(node.block)
          action = if action_source
            action_source.start_with?("do") ? "proc #{action_source}" : "proc#{action_source}"
          end
          if action
            state = states.last || :initial
            @eof_rules[state] = "proc { instance_exec(&self.class.__flexr_generated_eof_actions.fetch(#{state.inspect})) }"
            record_eof_edit(node, state, action)
          else
            record_deletion(node)
          end
        when :emits
          values = positional(node).map { |item| static(item) }.compact.flatten
          @config[:declared_tokens].concat(values.map(&:to_sym))
        when :keywords
          collect_keywords(node)
        when :indentation
          collect_indentation(node)
        when :backend
          @config[:backend] = Configuration.backend!(static(positional(node).first))
        when :token_kind
          @config[:token_kind] = Configuration.token_kind!(static(positional(node).first))
        when :encoding
          @config[:encoding] = Configuration.encoding!(static(positional(node).first))
        when :option
          @config[:options] ||= {}
          positional(node).each { |item| @config[:options][Configuration.option!(static(item))] = true }
        when :accel
          @config[:options] ||= {}
          @config[:options][:accel] = Configuration.accelerator!(static(positional(node).first))
        end
      rescue CompileError => e
        e.diagnostic.location ||= [node.location.start_offset, node.location.end_offset] if e.diagnostic
        raise
      end

      def collect_rule_namespaces(node, scope: [], nesting: [], qualified: false)
        case node
        when Prism::ProgramNode
          collect_rule_namespaces(node.statements, scope: scope, nesting: nesting, qualified: qualified)
        when Prism::StatementsNode
          node.body.each { |child| collect_rule_namespaces(child, scope: scope, nesting: nesting, qualified: qualified) }
        when Prism::ModuleNode, Prism::ClassNode
          nested_scope = scope + namespace_parts(node.constant_path)
          name = nested_scope.join("::")
          nested_nesting = [name, *nesting]
          offset = node.location.start_offset
          @lexer_rule_scopes = nested_nesting if offset == @lexer_offset
          @namespaces[name] << node
          qualified ||= node.constant_path.is_a?(Prism::ConstantPathNode)
          @rule_set_modules[offset] = [nested_scope, qualified] if
            node.is_a?(Prism::ModuleNode) && node.body&.body&.any? { |child| rule_set_extension?(child) }

          collect_rule_namespaces(node.body, scope: nested_scope, nesting: nested_nesting, qualified: qualified)
        end
      end

      def rule_set_extension?(node)
        return false unless node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :extend && !node.block

        arguments = Array(node.arguments&.arguments)
        arguments.one? && source_slice(arguments.first).delete_prefix("::") == "Flexr::Rules"
      end

      def collect_use(node, states)
        validate_keywords!(node, [])
        args = positional(node)
        unsupported_static!("use requires one named rule set without a block", node) unless args.one? && !node.block

        argument = args.first
        reference = source_slice(argument)
        declaration, scope = resolve_rule_set(argument)
        count, bindings = collect_shared_rules(declaration, states, scope)
        span = [node.location.start_offset, node.location.end_offset]
        @spans << span
        @edits << [*span, "__flexr_bind_rule_set(#{reference}, #{count}, #{bindings.inspect})"]
      end

      def resolve_rule_set(argument)
        reference = source_slice(argument)
        offset = argument.location.start_offset
        unless reference.match?(/\A(?:::)?[A-Z]\w*(?:::[A-Z]\w*)*\z/)
          unsupported_static!("use requires a literal rule set constant", argument,
                              help: "pass the name of a module extended with Flexr::Rules")
        end

        first, *tail = reference.delete_prefix("::").split("::")
        lexical_root = first
        unless reference.start_with?("::")
          [*Array(@lexer_rule_scopes), ""].each do |scope|
            candidate = [scope, first].reject(&:empty?).join("::")
            next unless @namespaces[candidate].any? { |node| node.location.start_offset < offset } ||
              assigned_constant?(candidate, offset)

            lexical_root = candidate
            break
          end
        end

        name = ([lexical_root] + tail).join("::")
        declarations = @namespaces[name].select { |node| node.location.end_offset < offset }
        declaration = declarations.first
        scope, qualified = @rule_set_modules[declaration.location.start_offset] if declaration
        if declarations.one? && scope && !assigned_constant?(lexical_root, offset) && !assigned_constant?(name, offset)
          if qualified
            unsupported_static!("qualified rule-set declarations can change lexical constant lookup", declaration.constant_path,
                                help: "declare the rule set within nested module blocks")
          end
          return [declaration, scope]
        end

        unsupported_static!("rule set could not be resolved in this file", argument,
                            help: "declare the module once before use and extend Flexr::Rules")
      end

      def assigned_constant?(name, offset)
        @constant_definitions.any? { |constant_name, _, _, position| constant_name == name && position < offset }
      end

      def collect_shared_rules(declaration, states, scope)
        entry = 0
        extended = false
        bindings = declaration.body.body.filter_map do |child|
          if rule_set_extension?(child)
            extended = true
            next
          end
          if child.is_a?(Prism::CallNode) && child.receiver.nil? && child.name == :rule
            unsupported_static!("extend Flexr::Rules before declaring rules", child) unless extended

            collect_shared_rule(child, states, scope)
            rule = @rules.last
            binding = [rule.index, entry] if rule.bind_action
            entry += 1
            binding
          else
            reject_unhandled_dsl!(child, any_receiver: true)
            nil
          end
        end
        [entry, bindings]
      end

      def collect_shared_rule(node, states, scope)
        saved_constants = @constants
        @constants = resolve_constants(before_offset: node.location.start_offset, constants: {}, resolved: {})
        collect_rule(node, states, scope: scope, shared: true)
      rescue CompileError => e
        e.diagnostic.location ||= [node.location.start_offset, node.location.end_offset] if e.diagnostic
        raise
      ensure
        @constants = saved_constants
      end

      def collect_keywords(node)
        validate_keywords!(node, %i[among])
        args = positional(node)
        among = keyword(node, :among)
        location = [node.location.start_offset, node.location.end_offset]
        Keywords.error!("keywords requires words and among:", location: location) unless args.one? && among && !node.block
        words = static(args.first)
        type = static(among)
        return if @allow_dynamic && (words.nil? || type.nil?)

        Keywords.add!(@config[:options] ||= {}, @config[:declared_tokens], words, among: type, location: location)
      end

      def collect_indentation(node)
        validate_keywords!(node, %i[newline indent dedent brackets tab_width])
        unsupported_static!("indentation requires keyword arguments", node) unless positional(node).empty? && !node.block

        options = keywords(node).transform_values { |value| static(value, scope: @lexer_scope) }
        return if @allow_dynamic && options.value?(nil)

        (@config[:options] ||= {})[:indentation] = Runtime::Indentation.configuration(**options)
      end

      def collect_state(node, parent_states)
        block = node.block
        raise ArgumentError, "state requires a block" unless block

        args = positional(node)
        names = args.map { |argument| static(argument, scope: @lexer_scope).to_sym }
        raise ArgumentError, "state requires a name" if names.empty?

        validate_keywords!(node, %i[inclusive match])
        inclusive = keyword(node, :inclusive) ? static(keyword(node, :inclusive), scope: @lexer_scope) : false
        location = [node.location.start_offset, node.location.end_offset]
        if (match_node = keyword(node, :match))
          collect_state_match(match_node, names) unless @allow_dynamic
          if names.include?(:initial) && !@initial_match_declared
            @states[:initial][:location] = location
            @initial_match_declared = true
          end
        end
        names.each do |name|
          existing = @states[name]
          raise ArgumentError, "state #{name.inspect} already declared with inclusive: #{existing[:inclusive]}" if
            existing && existing[:inclusive] != inclusive
          @states[name] ||= { inclusive: inclusive, location: location }
        end
        record_state_wrapper(node, block)
        collect_body(block.body, (parent_states + names).uniq)
      end

      def collect_state_match(node, names)
        match = static(node)
        DSL::ShortestStates.validate!(match)
        shortest = Array(@config.dig(:options, :shortest_states))
        names.each do |name|
          next if name == :initial && !@initial_match_declared
          next unless @states.key?(name)

          DSL::ShortestStates.agree!(name, match, shortest)
        end
        (@config[:options] ||= {})[:shortest_states] = (shortest | names).freeze if match == :shortest
      rescue ArgumentError => e
        diagnostic = Diagnostics.error("FLEXR-E018", e.message)
        raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
      end

      def collect_all_states(node, parent_states)
        block = node.block
        raise ArgumentError, "all_states requires a block" unless block

        validate_keywords!(node, [])
        unsupported_static!("all_states does not accept arguments", node) unless positional(node).empty?
        record_state_wrapper(node, block)
        collect_body(block.body, (parent_states + @states.keys).uniq)
      end

      def collect_rule(node, states, scope: @lexer_scope, shared: false)
        values = positional(node)
        patterns = static(values.first, scope: scope)
        patterns = [patterns] unless patterns.is_a?(Array)
        unless (@allow_dynamic && patterns.any?(&:nil?)) || patterns.all? { |pattern| pattern.is_a?(::Regexp) || pattern.is_a?(String) || pattern.is_a?(Pattern) }
          diagnostic = Diagnostics.error("FLEXR-E018", "rule pattern must be a Regexp, String, Pattern, or Array")
          raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
        end
        options = keywords(node)
        validate_keywords!(node, %i[skip emit followed_by channel priority emits])
        action_source = node.block && source_slice(node.block)
        if action_source && reject_action?(node.block)
          diagnostic = Diagnostics.error(
            "FLEXR-E013", "reject is not supported by flexr",
            help: "use a state transition and less(n) to express the fallback"
          )
          raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
        end
        block_action = if action_source
          action_source.start_with?("do") ? "proc #{action_source}" : "proc#{action_source}"
        end
        skip = options.key?(:skip) ? static(options[:skip], scope: scope) : false
        emit = options.key?(:emit) ? static(options[:emit], scope: scope) : nil
        emits = options[:emits] && Configuration.rule_emits!(
          static(options[:emits], scope: scope), emit: emit,
          location: [options[:emits].location.start_offset, options[:emits].location.end_offset]
        )
        priority = options.key?(:priority) ? static(options[:priority], scope: scope) : 0
        Configuration.rule_priority!(priority) unless @allow_dynamic && priority.nil?
        channel = options.key?(:channel) ? static(options[:channel], scope: scope) : :default
        dynamic_channel = @allow_dynamic && channel.nil?
        channel = dynamic_channel ? :default : Configuration.rule_channel!(channel)
        skip ||= channel == :skip
        channel = nil if skip || channel == :default
        action = ActionResolver.resolve(
          skip: skip, emit: emit, block: block_action, default: channel ? [:emit, channel] : "proc { emit(nil, text) }"
        )
        bind_action = !block_action.nil? && action.equal?(block_action)
        reads_locals = false
        if node.block
          each_node_including_self(node.block) do |child|
            reads_locals = true if child.is_a?(Prism::LocalVariableReadNode)
          end
        end
        rule_index = @rules.length
        if shared
          action = :__flexr_generated_method if bind_action
          action_source = nil
        else
          record_rule_edit(node, rule_index, bind_action ? block_action : nil)
        end
        @rules << RuleDefinition.new(
          index: rule_index, patterns: patterns,
          trailing: options[:followed_by] && static(options[:followed_by], scope: scope),
          action_source: action_source, action: action, states: states.dup, channel: channel, dynamic_channel: dynamic_channel,
          emits: emits,
          bol_only: false, end_anchor: nil, priority: priority, emit_shorthand: bind_action && !emits && emit_shorthand(node.block),
          span: [node.location.start_offset, node.location.end_offset], bind_action: bind_action, reads_locals: reads_locals,
          action_steps: (ActionEffects.steps(node.block) if bind_action)
        )
      end

      def emit_shorthand(block)
        return if block.parameters || !block.body.is_a?(Prism::StatementsNode) || !block.body.body.one?

        call = block.body.body.first
        return unless call.is_a?(Prism::CallNode) && call.name == :emit && call.receiver.nil? && call.block.nil?

        arguments = Array(call.arguments&.arguments)
        return unless (1..2).cover?(arguments.length) && arguments.first.is_a?(Prism::SymbolNode)

        value = arguments[1]
        return unless value.nil? || (value.is_a?(Prism::CallNode) && value.name == :text &&
          value.receiver.nil? && value.arguments.nil? && value.block.nil?)

        arguments.first.value.to_sym
      end

      def static(node, scope: @lexer_scope)
        StaticEval.new(@source, constants: @constants, scope: scope).call(node)
      rescue StaticResolutionError => e
        e.diagnostic.location ||= [node.location.start_offset, node.location.end_offset] if e.diagnostic && node
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
        unsupported_static!("unknown keyword #{unknown.first.inspect} for #{node.name}", node) unless unknown.empty?
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

      def record_eof_edit(node, state, action)
        span = [node.location.start_offset, node.location.end_offset]
        @spans << span
        @edits << [*span, "__flexr_bind_generated_eof(#{state.inspect}, #{action})"]
      end

      def reject_action?(block)
        found = false
        each_node_including_self(block.body) do |child|
          next unless child.class.name.end_with?("CallNode") && child.name.to_sym == :reject

          found ||= child.receiver.nil? || child.receiver.class.name.end_with?("SelfNode")
        end
        found
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

      def reject_unhandled_dsl!(node, any_receiver: false)
        each_node_including_self(node) do |child|
          next unless child.class.name.end_with?("CallNode")
          if %i[send public_send].include?(child.name.to_sym)
            dynamic_name = dynamically_dispatched_dsl(child)
            unsupported_static!("dynamic dispatch of #{dynamic_name} is not statically supported", child) if dynamic_name
          end
          next unless DSL_NAMES.include?(child.name.to_sym)
          next unless any_receiver || child.receiver.nil? || child.receiver.class.name.end_with?("SelfNode")

          unsupported_static!("#{child.name} must be a direct receiverless statement in a lexer or state body", child)
        end
      end

      def dynamically_dispatched_dsl(node)
        first_argument = Array(node.arguments&.arguments).first
        return unless first_argument && first_argument.class.name.end_with?("SymbolNode")

        name = first_argument.unescaped.to_sym
        name if DSL_NAMES.include?(name)
      end

      def unsupported_static!(reason, node, help: "move the DSL call to the lexer or state body, or use --eval")
        diagnostic = Diagnostics.error(
          "FLEXR-E017", "DSL structure is not statically supported",
          location: [node.location.start_offset, node.location.end_offset],
          help: help, note: reason
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
