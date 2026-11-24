# frozen_string_literal: true

require "digest"
require_relative "runtime" unless defined?(Flexr::Lexer)
require_relative "artifact_writer"
require_relative "codegen"
require_relative "source"

module Flexr
  class Generator
    attr_reader :diagnostics

    INLINE_EMIT = /\Aemit(?:\s+(.+?))?\z/
    INLINE_EMIT_ARGUMENTS = /\A(?::[A-Za-z_]\w*|true|false|nil|-?\d+(?:\.\d+)?|"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|text(?:\.(?:to_f|to_i|bytesize|byteslice\([^()\n]+\)))?|lineno|line)(?:\s*,\s*(?::[A-Za-z_]\w*|true|false|nil|-?\d+(?:\.\d+)?|"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|text(?:\.(?:to_f|to_i|bytesize|byteslice\([^()\n]+\)))?|lineno|line))*\z/

    RUNTIME_SOURCES = %w[
      version.rb errors.rb diagnostics.rb action_resolver.rb configuration.rb ir.rb
      unicode/version.rb automaton/types.rb automaton/dfa.rb automaton/accel.rb
      runtime/record.rb runtime/location.rb runtime/token.rb runtime/buffer.rb runtime/errors.rb
      runtime/interpreter.rb runtime/recognizer.rb runtime/core.rb runtime/checkpoint.rb dsl.rb lexer.rb generated.rb
    ].freeze

    DFA_ERROR_RUNTIME_SOURCES = %w[automaton/utf8.rb runtime/error_continuation.rb].freeze

    MATCHER_RUNTIME_SOURCES = %w[
      regexp/ast.rb regexp/parser.rb regexp/unsupported.rb
      unicode/utf8_splitter.rb unicode/data/properties.rb unicode/data/case_folding.rb
      unicode/property.rb unicode/reference_regexp.rb unicode/case_fold.rb regexp/matcher.rb automaton/reference_dfa.rb
    ].freeze

    def initialize(path, output: nil, eval_mode: false, options: {})
      @path = path
      @output = output
      @eval_mode = eval_mode
      @options = options
      @diagnostics = []
    end

    def generate
      ArtifactWriter.ensure_distinct!(@path, @output) if @output
      # Keep generated source stable when a checkout presents the spec with
      # Windows line endings. All offsets consumed by the parser and
      # passthrough writer are relative to this normalized source.
      source = File.binread(@path).gsub(/\r\n?/, "\n").force_encoding(Encoding::UTF_8)
      result = if @eval_mode
        generate_from_runtime(source)
      else
        parsed = Source::PrismReader.new(source, path: @path).read
        generate_static(parsed)
      end
      ArtifactWriter.write!(@output, result, source_path: @path) if @output
      result
    end

    private

    def generate_static(parsed)
      compiled = compile_parsed(parsed)
      @diagnostics = Array(compiled.diagnostics)
      validate_diagnostics!(compiled)
      payload = generated_payload(parsed, compiled)
      indent = Source::Passthrough.indentation(parsed.source, parsed.first_dsl_offset)
      install = "Flexr::Generated.install_compiled!(self, #{payload})\n"
      if parsed.config.dig(:options, :indentation)
        guard = 'Flexr::Generated.incompatible_artifact!("runtime lacks indentation support") unless respond_to?(:indentation)'
        install = "#{guard}\n#{indent}#{install}"
      end
      if parsed.rules.any? { |rule| !rule.priority.to_i.zero? }
        guard = 'Flexr::Generated.incompatible_artifact!("runtime does not support explicit rule priority")' \
          ' unless Flexr::IR::Rule.method_defined?(:loses_priority_tie?)'
        install = "#{guard}\n#{indent}#{install}"
      end
      if parsed.rules.any?(&:channel)
        guard = 'Flexr::Generated.incompatible_artifact!("runtime does not support token channels")' \
          ' unless defined?(Flexr::Runtime::Channels)'
        install = "#{guard}\n#{indent}#{install}"
      end
      if compiled.rules.any?(&:capture_patterns)
        guard = 'Flexr::Generated.incompatible_artifact!("runtime does not support named regexp captures")' \
          ' unless defined?(Flexr::Runtime::Captures)'
        install = "#{guard}\n#{indent}#{install}"
      end
      if regexp_end_context?(compiled) || compiled.rules.any? { |rule| rule.capture_patterns&.any?(Array) }
        capability = if regexp_end_context?(compiled)
          "defined?(Flexr::Automaton::EndContext)"
        else
          "Flexr::Automaton::Acceptance.method_defined?(:valid_end?)"
        end
        guard = 'Flexr::Generated.incompatible_artifact!("runtime does not support next-byte conditions")'
        install = "#{guard} unless #{capability}\n#{indent}#{install}"
      end
      if compiled.rules.any?(&:contextual_patterns)
        guard = 'Flexr::Generated.incompatible_artifact!("runtime does not support ordered regexp context")' \
          ' unless defined?(Flexr::Runtime::ContextualRegexp)'
        install = "#{guard}\n#{indent}#{install}"
      end
      if compiled.rules.any? { |rule| rule.contextual_patterns&.any? { |pattern| pattern&.replay } }
        guard = 'Flexr::Generated.incompatible_artifact!("runtime does not support ordered streaming regexp selection")'
        guard += ' unless defined?(Flexr::Runtime::ContextualRegexp) && Flexr::Runtime::ContextualRegexp.method_defined?(:replay)'
        install = "#{guard}\n#{indent}#{install}"
      end
      if compiled.rules.any? { |rule| rule.contextual_patterns&.any? { |pattern| pattern&.invalid_eof } }
        guard = 'Flexr::Generated.incompatible_artifact!("runtime does not support regexp source-end assertions")'
        guard += ' unless defined?(Flexr::Runtime::ContextualRegexp) && Flexr::Runtime::ContextualRegexp.method_defined?(:invalid_eof)'
        install = "#{guard}\n#{indent}#{install}"
      end
      if compiled.rules.any? { |rule| rule.contextual_patterns&.any? { |pattern| pattern&.capture_names } }
        guard = 'Flexr::Generated.incompatible_artifact!("runtime does not support regexp word boundary captures")'
        guard += ' unless defined?(Flexr::Runtime::ContextualRegexp) && Flexr::Runtime::ContextualRegexp.method_defined?(:capture_names)'
        install = "#{guard}\n#{indent}#{install}"
      end
      if regexp_lookbehind?(compiled)
        guard = 'Flexr::Generated.incompatible_artifact!("runtime does not support regexp lookbehind")' \
          ' unless defined?(Flexr::Runtime::Lookbehind)'
        install = "#{guard}\n#{indent}#{install}"
      end
      if regexp_left_context?(compiled)
        guard = 'Flexr::Generated.incompatible_artifact!("runtime does not support regexp left context")' \
          ' unless defined?(Flexr::Automaton::LeftContext)'
        install = "#{guard}\n#{indent}#{install}"
      end
      if regexp_lookahead?(compiled)
        guard = 'Flexr::Generated.incompatible_artifact!("runtime does not support regexp lookahead")' \
          ' unless defined?(Flexr::Automaton::Lookahead)'
        install = "#{guard}\n#{indent}#{install}"
      end
      if uses_delegation?(parsed)
        guard = 'Flexr::Generated.incompatible_artifact!("runtime does not support lexer delegation")' \
          ' unless defined?(Flexr::Runtime::DelegatedTokens)'
        install = "#{guard}\n#{indent}#{install}"
      end
      scanner = Codegen::Table.new(compiled).source(
        indent: indent, direct: effective_backend(parsed) == :direct, packed: table_format == :packed
      )
      install = "#{install}#{scanner}"
      install = "#{install}#{generated_action_source(parsed, indent)}"
      edits = parsed.dsl_edits.dup
      parsed.rules.each do |rule|
        next unless rule.bind_action && !rule.reads_locals && inline_simple_action(rule.action_source)

        edits.map! { |edit| edit.first(2) == rule.span ? [*rule.span, ""] : edit }
      end
      edits.concat(parsed.flexr_require_spans.map { |span| [*span, ""] }) if standalone?(parsed)
      result = Source::Passthrough.rewrite(
        parsed.source, edits, insertion: parsed.first_dsl_offset, payload: install
      )
      digest = Digest::SHA256.hexdigest(result)
      header = [
        "# Generated by flexr. DO NOT EDIT.",
        "# source: #{parsed.path}",
        "# spec-digest: sha256:#{digest}",
        "# artifact-schema: #{Generated::ARTIFACT_SCHEMA_VERSION}",
        "# runtime-abi: #{Generated::RUNTIME_ABI_VERSION}",
        "# unicode: #{Unicode::VERSION}",
        "# backend: #{effective_backend(parsed)}",
        "# compiled: true",
        "# eval: #{@eval_mode}",
        "# standalone: #{standalone?(parsed)}"
      ].join("\n")
      prefix = standalone?(parsed) ? "raise LoadError, \"flexr requires Ruby 3.4 or newer\" if RUBY_VERSION < \"3.4\"\nrequire \"json\"\nrequire \"monitor\"\n#{embedded_runtime(parsed, compiled)}\n" : ""
      Source::Passthrough.insert_after_preamble(result, "#{header}\n#{prefix}")
    end

    def generated_payload(parsed, compiled)
      definitions = parsed.rules.map do |rule|
        compiled_rule = compiled.rules.fetch(rule.index)
        conditions = Array(rule.pattern_conditions).map do |condition|
          [condition.rule_index, condition.pattern_index, condition.bol_only, condition.end_anchor]
        end
        priority = ("priority: #{rule.priority}, " unless rule.priority.to_i.zero?)
        channel = "channel: #{ruby_literal(rule.channel)}, " if rule.channel
        emits = "emits: #{ruby_literal(rule.emits)}, " if rule.emits
        capture_patterns = compiled_rule.capture_patterns
        captures = "capture_patterns: #{ruby_literal(capture_patterns)}, " if capture_patterns
        tagged = tagged_capture_expression(compiled_rule.tagged_capture_programs) if
          compiled_rule.respond_to?(:tagged_capture_programs)
        contextual = compiled_rule.contextual_patterns
        context = "contextual_patterns: #{ruby_literal(contextual)}, " if contextual
        "{ index: #{rule.index}, patterns: #{ruby_literal(rule.patterns)}, pattern_conditions: #{ruby_literal(conditions)}, trailing: #{ruby_literal(rule.trailing)}, " \
          "#{trailing_dfa_expression(rule, parsed, compiled_rule.trailing_dfa)}" \
          "#{priority}" \
          "action: #{generated_rule_action(rule)}, states: #{rule.states.inspect}, " \
          "#{channel}#{emits}#{captures}#{tagged}#{context}bol_only: #{ruby_literal(rule.bol_only)}, end_anchor: #{ruby_literal(rule.end_anchor)} }"
      end
      "{ artifact: #{ruby_literal(artifact_metadata)}, rules: [#{definitions.join(', ')}], " \
        "backend: #{ruby_literal(effective_backend(parsed))}, " \
        "token_kind: #{ruby_literal(@options.fetch(:token_kind, parsed.config[:token_kind]))}, " \
        "encoding: #{encoding_expression(parsed.config[:encoding])}, " \
        "declared_tokens: #{ruby_literal(parsed.config[:declared_tokens])}, " \
        "options: #{ruby_literal(effective_options(parsed))}, " \
        "eof_rules: #{eof_rules_expression(parsed.config[:eof_rules] || {})}, " \
        "states: #{ruby_literal(parsed.states.keys.reject { |name| name == :initial })}, " \
        "inclusive_states: #{ruby_literal(parsed.states.transform_values { |value| value[:inclusive] })}, " \
        "compiled: #{compiled_expression(compiled, compression: table_compression(parsed),
                                         backend: effective_backend(parsed))} }"
    end

    def tagged_capture_expression(programs)
      return unless programs

      definitions = programs.map do |program|
        next unless program
        next {whole_capture: program.whole_capture, encoding: program.encoding.name} if program.whole_capture

        rows = program.transitions.map do |row|
          row.each_index.chunk { |index| row.fetch(index) }.filter_map do |step, classes|
            [classes.first, classes.last, *step] if step
          end
        end
        {byte_classes: program.byte_classes, rows: rows, acceptances: program.acceptances, groups: program.groups,
         register_count: program.register_count, encoding: program.encoding.name}
      end
      "tagged_capture_program_data: #{ruby_literal(definitions)}, "
    end

    def artifact_metadata
      Generated.artifact_metadata
    end

    def compile_parsed(parsed, construction: Automaton::Compiler::DEFAULT_CONSTRUCTION)
      states = parsed.states.each_with_index.to_h do |(name, value), index|
        [name.to_sym, IR::State.new(name: name.to_sym, inclusive: value[:inclusive], id: index, location: value[:location])]
      end
      rules = parsed.rules.map do |rule|
        IR::Rule.new(index: rule.index, patterns: rule.patterns, trailing: normalize_trailing(rule.trailing),
                     action: rule.action, states: rule.states, bol_only: rule.bol_only,
                     end_anchor: rule.end_anchor, location: rule.span, channel: rule.channel, priority: rule.priority, emits: rule.emits)
      rescue CompileError => e
        e.diagnostic.location ||= rule.span if e.diagnostic
        raise
      end
      spec = IR::Spec.new(
        class_name: parsed.class_name, superclass: "Flexr::Lexer",
        backend: @options.fetch(:backend, parsed.config[:backend]),
        token_kind: @options.fetch(:token_kind, parsed.config[:token_kind]),
        encoding: parsed.config[:encoding], options: effective_options(parsed).merge(warn_level: @options[:warn_level]),
        declared_tokens: parsed.config[:declared_tokens], states: states, rules: rules,
        eof_rules: parsed.config[:eof_rules] || {}, verbatim: parsed.source
      )
      compiled = Automaton::Compiler.new(spec, construction: construction).compile
      @resolved_backend = resolve_backend(spec.backend, compiled)
      parsed.rules.each do |rule|
        compiled_rule = spec.rules.fetch(rule.index)
        rule.pattern_conditions = compiled_rule.pattern_conditions
      end
      compiled
    end

    def effective_backend(parsed)
      @resolved_backend || resolve_backend(@options.fetch(:backend, parsed.config[:backend]).to_sym, nil)
    end

    def resolve_backend(requested, compiled)
      return requested unless requested == :auto
      return :table unless compiled

      Automaton::BackendCostModel.choose(compiled)
    end

    def normalize_trailing(value)
      case value
      when nil, ::Regexp, Pattern
        value
      when String
        ::Regexp.new(::Regexp.escape(value))
      else
        diagnostic = Diagnostics.error("FLEXR-E018", "followed_by must be a Regexp, String, or Pattern")
        raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
      end
    end

    def compiled_expression(compiled, compression: :none, backend: :table)
      machines = compiled.machines.map do |name, machine|
        direct = Codegen::Direct.new(compiled).generate(state: name) if backend == :direct
        data = dfa_data(machine.dfa, compression: compression, direct: direct)
        flags = { backup_memo_states: machine.backup_memo_states, backup_recovery_states: machine.backup_recovery_states }
        fields = flags.compact.map { |field, states| ", #{field}: #{ruby_literal(states)}" }.join
        "#{ruby_literal(name)} => { state_name: #{ruby_literal(machine.state_name)}, dfa: #{ruby_literal(data)}#{fields} }"
      end
      # W016 is derived from wall-clock compilation time and must not make
      # generated source (or its golden digest) vary between runs.
      diagnostics = compiled.diagnostics.reject { |diagnostic| diagnostic.code == "FLEXR-W016" }.map(&:to_h)
      "{ machines: { #{machines.join(', ')} }, states: #{ruby_literal(compiled.states)}, " \
        "stats: #{ruby_literal(compiled.stats)}, diagnostics: #{ruby_literal(diagnostics)} }"
    end

    def trailing_dfa_expression(rule, parsed, dfa)
      return "" unless rule.trailing

      dfa ||= Flexr.compile_pattern(normalize_trailing(rule.trailing), encoding: parsed.config[:encoding],
                                   options: { unicode: effective_options(parsed)[:unicode] == true })
      "trailing_dfa: #{ruby_literal(dfa_data(dfa, compression: table_compression(parsed)))}, "
    rescue CompileError => e
      e.diagnostic.location ||= rule.span if e.diagnostic
      raise
    end

    def dfa_data(dfa, compression:, direct: nil)
      data = {
        **dfa.acceptance_data, ec: dfa.ec, class_count: dfa.class_count,
        state_count: dfa.states, start: dfa.start, rule_ids: dfa.rule_ids
      }
      data[:starts] = dfa.starts if dfa.starts
      data[:left_context] = dfa.left_context.to_h if dfa.left_context
      pack_tables = %i[rows full].include?(compression) || table_format == :packed
      if direct
        data[:direct] = direct
      elsif pack_tables
        packed = Codegen::TablePacker.pack(dfa.transitions, compression: compression)
        data[:packed] = if table_format == :packed
          Codegen::TablePacker.encode(packed)
        else
          packed
        end
      else
        data[:transitions] = dfa.transitions
      end
      data
    end

    def standalone?(parsed)
      @options.fetch(:standalone, parsed.config[:options]&.key?(:standalone) || false)
    end

    def effective_options(parsed)
      options = (parsed.config[:options] || {}).dup
      %i[accel max_dfa_states table_compression table_format].each do |name|
        options[name] = @options[name] if @options.key?(name)
      end
      options[:standalone] = true if standalone?(parsed)
      options
    end

    def table_compression(parsed)
      @options.fetch(:table_compression, parsed.config[:options]&.fetch(:table_compression, :rows) || :rows).to_sym
    end

    def table_format
      @options.fetch(:table_format, :literal).to_sym
    end

    def embedded_runtime(parsed, compiled)
      sources = RUNTIME_SOURCES.dup
      sources << "automaton/end_context.rb" if regexp_end_context?(compiled) || compiled.rules.any?(&:contextual_patterns)
      sources << "automaton/left_context.rb" if regexp_left_context?(compiled)
      sources << "runtime/lookbehind.rb" if regexp_lookbehind?(compiled)
      sources << "automaton/lookahead.rb" if regexp_lookahead?(compiled) || compiled.rules.any?(&:contextual_patterns)
      sources << "runtime/contextual_regexp.rb" if compiled.rules.any?(&:contextual_patterns)
      sources.insert(sources.index("runtime/checkpoint.rb"), "runtime/backup_memo.rb") if
        compiled.machines.values.any? { |machine| machine.backup_memo_states || machine.backup_recovery_states }
      sources << "runtime/input_stack.rb" if parsed.uses_input_stack || parsed.config.dig(:options, :input_stack)
      sources << "runtime/indentation.rb" if parsed.config.dig(:options, :indentation)
      sources << "runtime/delimiters.rb" if parsed.uses_dynamic_delimiters || parsed.config.dig(:options, :dynamic_delimiters)
      if effective_backend(parsed) == :firstmatch
        sources.insert(sources.index("runtime/interpreter.rb"), "runtime/firstmatch.rb")
      else
        sources.concat(DFA_ERROR_RUNTIME_SOURCES)
      end
      sources.insert(6, *MATCHER_RUNTIME_SOURCES) if matcher_runtime?(parsed)
      sources.insert(6, "pattern.rb") if parsed.uses_patterns ||
        parsed.rules.any? { |rule| rule.trailing.is_a?(Pattern) || rule.patterns.any?(Pattern) }
      sources << "runtime/channels.rb" if parsed.uses_rule_sets || parsed.rules.any?(&:channel) || uses_delegation?(parsed)
      sources << "runtime/captures.rb" if compiled.rules.any?(&:capture_patterns)
      sources.push("automaton/tagged_dfa.rb", "runtime/tagged_captures.rb", "generated/tagged_capture_programs.rb") if
        compiled.rules.any? { |rule| rule.respond_to?(:tagged_capture_programs) && rule.tagged_capture_programs }
      sources << "runtime/tagged_trailing.rb" if effective_backend(parsed) != :firstmatch && compiled.rules.any?(&:trailing)
      sources << "runtime/delegation.rb" if uses_delegation?(parsed)
      sources << "rules.rb" if parsed.uses_rule_sets
      sources.map do |relative|
        File.binread(File.expand_path(relative, __dir__)).gsub(/\r\n?/, "\n")
      end.join("\n")
    end

    def regexp_end_context?(compiled)
      compiled.machines.values.any? { |machine| machine.dfa.context_dependent_end? } ||
        compiled.rules.any? { |rule| rule.trailing_dfa&.context_dependent_end? }
    end

    def regexp_left_context?(compiled)
      compiled.machines.values.any? { |machine| machine.dfa.starts } ||
        compiled.rules.any? do |rule|
          rule.trailing_dfa&.starts || rule.contextual_patterns&.any? { |pattern| pattern&.left_context }
        end
    end

    def regexp_lookbehind?(compiled)
      !Runtime::Lookbehind.graphs(compiled).empty?
    end

    def regexp_lookahead?(compiled)
      compiled.machines.values.any? { |machine| machine.dfa.lookahead? } ||
        compiled.rules.any? { |rule| rule.trailing_dfa&.lookahead? }
    end

    def matcher_runtime?(parsed)
      effective_backend(parsed) == :firstmatch || parsed.rules.any?(&:trailing)
    end

    def uses_delegation?(parsed)
      parsed.uses_delegation || parsed.config.dig(:options, :delegation)
    end

    def encoding_expression(encoding)
      encoding == Encoding::BINARY ? "Encoding::BINARY" : "Encoding::UTF_8"
    end

    def eof_rules_expression(rules)
      pairs = rules.map { |state, action| "#{ruby_literal(state)} => #{action_expression(action)}" }
      "{ #{pairs.join(', ')} }"
    end

    def action_expression(action)
      return action if action.is_a?(String) && action.start_with?("proc")
      return ruby_literal(action) unless action.is_a?(Proc)

      "proc { emit(nil, text) }"
    end

    def generated_rule_action(rule)
      return ruby_literal(:__flexr_generated_method) if rule.action.is_a?(String) &&
        ((!rule.bind_action && !inline_action_body(rule).nil?) || (!rule.reads_locals && inline_simple_action(rule.action_source)))

      action_expression(rule.action)
    end

    def generated_action_source(parsed, indent)
      lines = ["#{indent}def __flexr_generated_execute(rule)", "#{indent}  case rule.index"]
      keyword_tables = parsed.config.dig(:options, :keyword_tables)
      parsed.rules.each do |rule|
        lines << "#{indent}  when #{rule.index}"
        body = inline_simple_action(rule.action_source) if rule.bind_action && !rule.reads_locals
        if rule.bind_action && body.nil?
          lines << "#{indent}    instance_exec(&self.class.__flexr_generated_actions.fetch(rule.index))"
          next
        end
        body ||= inline_action_body(rule, keyword_tables: keyword_tables)
        if body.nil?
          lines << "#{indent}    instance_exec(&rule.action)"
        else
          body.lines.each { |line| lines << "#{indent}    #{line.rstrip}" }
        end
      end
      lines << "#{indent}  else"
      lines << "#{indent}    instance_exec(&rule.action)"
      lines << "#{indent}  end"
      lines << "#{indent}end\n"
      lines.join("\n")
    end

    def inline_action_body(rule, keyword_tables: nil)
      action = rule.action
      case action
      when :skip
        ""
      when Array
        return unless action.first == :emit

        type = action.fetch(1)
        return keyword_action_body(type) if !rule.channel && keyword_tables&.key?(type)

        "emit(#{ruby_literal(type)}, text)"
      when String
        return inline_simple_action(rule.action_source) if rule.action_source
        return unless action.start_with?("proc")

        body = action.delete_prefix("proc").strip
        if body.start_with?("{") && body.end_with?("}")
          body = body[1...-1]
          return nil if body.lstrip.start_with?("|")
          return body.strip
        end
        return nil unless body.start_with?("do") && body.end_with?("end")

        body.delete_prefix("do")[0...-3].strip
      end
    end

    def keyword_action_body(type)
      literal = ruby_literal(type)
      <<~RUBY
        value = text
        lexeme = @text_start == @match_start ? value : @buffer.byteslice(@match_start...@match_end)
        lexeme = lexeme.dup.force_encoding(::Encoding::UTF_8) unless lexeme.encoding == ::Encoding::UTF_8
        entry = self.class.__flexr_config.options.fetch(:keyword_tables).fetch(#{literal})[lexeme]
        emit(entry ? entry.first : #{literal}, value)
      RUBY
    end

    # Hash#inspect changed from hash rockets to keyword-style labels in Ruby
    # 4. Generated source and its golden digests must be identical on every
    # supported Ruby, so serialize the small set of Ruby literals used in the
    # generated payload ourselves.
    def ruby_literal(value)
      case value
      when Hash
        return "{}" if value.empty?

        entries = value.map do |key, nested|
          if key.is_a?(Symbol) && key.to_s.match?(/\A[a-zA-Z_]\w*\z/)
            "#{key}: #{ruby_literal(nested)}"
          else
            "#{ruby_literal(key)} => #{ruby_literal(nested)}"
          end
        end
        "{#{entries.join(', ')}}"
      when Array
        "[#{value.map { |item| ruby_literal(item) }.join(', ')}]"
      when Automaton::Acceptance
        "::Flexr::Automaton::Acceptance.new(**#{ruby_literal(value.to_h)})"
      when Automaton::LeftContext::Graph
        "::Flexr::Automaton::LeftContext::Graph.new(**#{ruby_literal(value.to_h)})"
      when Automaton::Lookahead
        "::Flexr::Automaton::Lookahead.new(**#{ruby_literal(value.to_h)})"
      when Automaton::DFA
        "::Flexr::Generated.load_dfa(#{ruby_literal(dfa_data(value, compression: :rows))})"
      when Runtime::ContextualRegexp
        definition = value.to_h
        definition.delete(:invalid_eof) unless value.invalid_eof
        definition.delete(:left_context) unless value.left_context
        definition.delete(:replay) unless value.replay
        %i[history_bytes invalid_left invalid_both capture_names].each { |key| definition.delete(key) unless definition[key] }
        "::Flexr::Runtime::ContextualRegexp.new(**#{ruby_literal(definition)})"
      when Pattern
        "::Flexr::Pattern.__flexr_restore(#{value.operation.inspect}, #{ruby_literal(value.operands)}, #{ruby_literal(value.name)})"
      else
        value.inspect
      end
    end

    def inline_simple_action(source)
      body = source.to_s.strip
      return if body.include?('#{') || body.match?(/text\.byteslice\([^)]*[A-Za-z_]/)
      body = body[1...-1].strip if body.start_with?("{") && body.end_with?("}")
      match = INLINE_EMIT.match(body)
      return unless match

      arguments = match[1].to_s.strip
      return unless arguments.empty? || INLINE_EMIT_ARGUMENTS.match?(arguments)

      arguments.empty? ? "emit" : "emit #{arguments}"
    end

    def validate_diagnostics!(compiled)
      return unless @options[:warn_as_error]

      diagnostic = Array(compiled.diagnostics).find do |item|
        item.warning? && (@options.fetch(:warn_level, :default) == :all || item.code != "FLEXR-W016")
      end
      return unless diagnostic

      raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
    end

    def generate_from_runtime(source)
      loader = Object.new
      loader.define_singleton_method(:load_spec) do
        # --eval is opt-in and intentionally executes trusted specification code.
        eval(source, TOPLEVEL_BINDING, @path, 1) # rubocop:disable Security/Eval
      end
      loader.instance_variable_set(:@path, @path)
      loader.load_spec
      passthrough = Source::PrismReader.new(source, path: @path).read(allow_dynamic: true)
      classes = ObjectSpace.each_object(Class).select { |klass| klass.respond_to?(:__flexr_spec) }
      classes.select! do |klass|
        name = klass.name.to_s
        (passthrough.class_name.nil? || name == passthrough.class_name || name.end_with?("::#{passthrough.class_name}")) &&
          klass != Flexr::Lexer && klass.__flexr_rules.any?
      end
      klass = classes.last
      raise CompileError, "--eval could not find a Flexr::Lexer class" unless klass

      # --eval is intentionally explicit; the generated file still contains
      # executable action source, but its metadata is deterministic for this run.
      parsed = klass.__flexr_spec
      if (indentation = parsed.options[:indentation])
        (passthrough.config[:options] ||= {})[:indentation] = indentation
      end
      if (tables = parsed.options[:keyword_tables])
        (passthrough.config[:options] ||= {})[:keyword_tables] = tables
        passthrough.config[:declared_tokens] |= parsed.declared_tokens
      end
      runtime_rules = parsed.rules.to_h { |rule| [rule.index, rule] }
      passthrough.rules.each do |rule|
        runtime_rule = runtime_rules.fetch(rule.index)
        rule.patterns = runtime_rule.patterns
        rule.trailing = runtime_rule.trailing
        rule.emits = runtime_rule.emits
        rule.priority = runtime_rule.priority
        next unless rule.dynamic_channel || rule.channel || runtime_rule.channel

        rule.channel = runtime_rule.channel
        next unless runtime_rule.skip? || runtime_rule.emit?

        rule.action = runtime_rule.action
        next unless rule.bind_action

        rule.bind_action = false
        passthrough.dsl_edits.map! { |edit| edit.first(2) == rule.span ? [*rule.span, ""] : edit }
      end
      generate_static(passthrough)
    end
  end
end
