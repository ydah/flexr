# frozen_string_literal: true

require_relative "runtime" unless defined?(Flexr::Lexer)
require_relative "artifact_writer"
require_relative "generator"
require_relative "importer"
require_relative "options"
require_relative "migration"

module Flexr
  module CLI
    COMMANDS = %w[check fix stats tokens dot explain trace skeleton bench import new].freeze
    EXIT_OK = 0
    EXIT_FAILURE = 1
    EXIT_USAGE = 2

    module_function

    def run(argv, out: $stdout, err: $stderr)
      args = argv.dup
      command = COMMANDS.include?(args.first) ? args.shift.to_sym : :generate
      if args.include?("--help") || args.include?("-h")
        return command == :new ? new_project_usage(out) : usage(out)
      end
      return version(out) if args.delete("--version")
      return new_project(args, out) if command == :new

      options, output, rule_number, benchmark_args, positionals, command_args = parse(args, command)
      raise ArgumentError, "lrama format is only valid for tokens" if options.format == :lrama && command != :tokens
      spec = positionals.shift
      raise ArgumentError, "a SPEC.rb path is required" unless spec
      raise ArgumentError, "unexpected argument: #{positionals.first}" unless positionals.empty?

      execute(command, spec, options, output, rule_number, benchmark_args, out, err, command_args: command_args)
    rescue ArgumentError => e
      err.puts "error: #{e.message}"
      command == :new ? new_project_usage(err, status: EXIT_USAGE) : usage(err, status: EXIT_USAGE)
    rescue Flexr::Error, Errno::ENOENT, Errno::EACCES, SyntaxError => e
      err.puts render_error(e, options: options, path: spec,
                           normalize_source: command == :generate || (command == :check && options&.eval_mode))
      EXIT_FAILURE
    rescue StandardError => e
      err.puts "error: #{e.class}: #{e.message}"
      EXIT_FAILURE
    end

    def new_project(args, out)
      require "optparse"
      require_relative "project_template"

      parser = nil
      OptionParser.new do |options|
        options.require_exact = true
        options.on("--parser PARSER") do |value|
          raise ArgumentError, "--parser may only be given once" if parser

          parser = value
        end
      end.parse!(args)
      raise ArgumentError, "a project name is required" if args.empty?
      raise ArgumentError, "unexpected argument: #{args[1]}" if args.length > 1

      ProjectTemplate.create(args.first, parser: parser)
      out.puts "Created #{args.first} with #{parser}. See #{args.first}/README.md to get started."
      EXIT_OK
    rescue OptionParser::ParseError => e
      raise ArgumentError, e.message
    end

    def new_project_usage(out, status: EXIT_OK)
      out.puts "Usage: flexr new NAME --parser lrama|racc"
      out.puts "Create a calculator project in a new directory in the current directory."
      status
    end

    def parse(args, command)
      options = Options.default
      output = nil
      rule_number = nil
      benchmark_args = []
      positionals = []
      command_args = {}
      parsing_options = true

      until args.empty?
        argument = args.shift
        if parsing_options && argument == "--"
          parsing_options = false
          next
        end
        unless parsing_options && argument.start_with?("-")
          positionals << argument
          next
        end

        case argument
        when "-o", "--output"
          output = required_argument!(args, argument)
        when "-b", "--backend"
          options.set(:backend, required_argument!(args, argument).to_sym)
        when "--token-kind"
          options.set(:token_kind, required_argument!(args, argument).to_sym)
        when "--accel"
          options.set(:accel, required_argument!(args, argument).to_sym)
        when "--standalone"
          options.set(:standalone, true)
        when "--eval"
          raise ArgumentError, "fix requires a statically readable spec" if command == :fix
          options.eval_mode = true
        when "--dry-run"
          raise ArgumentError, "--dry-run is only valid for fix" unless command == :fix
          options.dry_run = true
        when "--table-compression"
          options.set(:table_compression, required_argument!(args, argument).to_sym)
        when "--table-format"
          options.set(:table_format, required_argument!(args, argument).to_sym)
        when "--max-dfa-states"
          options.set(:max_dfa_states, Integer(required_argument!(args, argument), 10))
        when "-W", "--warn"
          options.set(:warn_level, required_argument!(args, argument).to_sym)
        when "--warn-as-error"
          options.warn_as_error = true
        when "--color"
          options.color = required_argument!(args, argument).to_sym
        when "--format"
          options.format = required_argument!(args, argument).to_sym
        when "--target"
          raise ArgumentError, "--target is only valid for the check command" unless command == :check
          options.target = required_argument!(args, argument)
        when "--from"
          raise ArgumentError, "--from is only valid for import" unless command == :import
          options.import_format = required_argument!(args, argument).to_sym
        when "--rule"
          rule_number = Integer(required_argument!(args, argument), 10)
          raise ArgumentError, "--rule must be non-negative" if rule_number.negative?
        when "--grammar"
          raise ArgumentError, "--grammar is only valid for check" unless command == :check
          options.grammar = required_argument!(args, argument)
        when "--verify"
          raise ArgumentError, "--verify is only valid for the skeleton command" unless command == :skeleton
          command_args[:verify] = true
        when "--residuals"
          raise ArgumentError, "--residuals is only valid for explain or trace" unless %i[explain trace].include?(command)

          command_args[:residuals] = true
        when "--input", "--generated"
          raise ArgumentError, "#{argument} is only valid for the trace command" unless command == :trace
          if argument == "--generated"
            command_args[:generated] = true
          else
            command_args[:input] = args.shift || raise(ArgumentError, "--input requires a value")
          end
        when "--input-file"
          value = required_argument!(args, argument)
          if command == :trace
            command_args[:input_file] = value
          elsif command == :bench
            benchmark_args.push(argument, value)
          else
            raise ArgumentError, "#{argument} is only valid for the trace or bench command"
          end
        when "--baseline", "--iterations"
          raise ArgumentError, "#{argument} is only valid for the bench command" unless command == :bench
          benchmark_args.push(argument, required_argument!(args, argument))
        else
          raise ArgumentError, "unknown option: #{argument}"
        end
      end

      options.validate!
      raise ArgumentError, "skeleton requires static compilation; remove --eval" if command == :skeleton && options.eval_mode
      raise ArgumentError, "choose --input or --input-file" if command_args.key?(:input) && command_args[:input_file]
      raise ArgumentError, "--generated requires --input or --input-file" if
        command_args[:generated] && !command_args.key?(:input) && !command_args[:input_file]
      [options, output, rule_number, benchmark_args, positionals, command_args]
    rescue ArgumentError => e
      raise e if e.message.start_with?("unsupported ", "--rule")

      raise ArgumentError, "invalid option value: #{e.message}"
    end

    def execute(command, spec, options, output, rule_number, benchmark_args, out, err, command_args: {})
      case command
      when :check
        check(spec, options, out)
      when :fix
        fix(spec, options, out)
      when :stats
        print_stats(spec, options, out)
      when :tokens
        parsed = read_spec(spec)
        tokens = Array(parsed.config[:declared_tokens])
        if options.format == :lrama
          require_relative "grammar"
          out.puts Grammar.declarations(tokens)
        else
          out.puts tokens.join(" ")
        end
        EXIT_OK
      when :dot
        print_dot(spec, options, out)
      when :explain
        print_explanation(spec, options, rule_number, out, residuals: command_args[:residuals])
      when :trace
        if command_args.key?(:input) || command_args[:input_file]
          print_input_trace(spec, options, command_args, out)
        else
          print_trace(spec, options, out, residuals: command_args[:residuals])
        end
      when :skeleton
        print_skeleton(spec, options, out, verify: command_args[:verify])
      when :bench
        run_benchmark(spec, options, benchmark_args, out)
      when :import
        result = Importer.import(spec, from: options.import_format)
        result.warnings.each { |warning| err.puts "warning: #{warning}" }
        return EXIT_FAILURE unless result.complete?

        if output
          ArtifactWriter.write!(output, result.source, source_path: spec)
        else
          out.write(result.source)
        end
        EXIT_OK
      when :generate
        target = output || ArtifactWriter.default_generated_path(spec)
        Generator.new(spec, output: target, eval_mode: options.eval_mode,
                      options: options.generator_options).generate
        EXIT_OK
      end
    end

    def fix(spec, options, out)
      require_relative "source/fixes"
      path = File.realpath(spec)
      parsed = read_spec(path)
      original = parsed
      begin
        compiled = compile(parsed, overrides: { warn_level: :all })
      rescue CompileError => e
        repairs = Source::Fixes.regexp_edits(parsed, e.diagnostic)
        if repairs.empty?
          index = parsed.rules.index { |rule| rule.span == e.diagnostic&.location }
          e.diagnostic.location = original.rules.fetch(index).span if index
          raise
        end

        repaired = Source::Fixes.apply(parsed.source, repairs)
        parsed = Source::PrismReader.new(repaired, path: path).read
        retry
      end
      edits = Source::Fixes.edits(parsed, compiled)
      fixed = Source::Fixes.apply(parsed.source, edits)
      compile(Source::PrismReader.new(fixed, path: path).read) unless edits.empty?

      if options.dry_run
        out.write(fixed)
      elsif fixed != original.source
        raise CompileError, "spec changed while preparing fixes: #{spec}" unless File.binread(path) == original.source.b

        ArtifactWriter.write!(path, fixed)
      end
      EXIT_OK
    end

    def check(spec, options, out)
      compiled = if options.eval_mode
                   generator = Generator.new(spec, eval_mode: true, options: options.generator_options)
                   generator.generate
                   generator.diagnostics
                 else
                   parsed = read_spec(spec)
                   compile(parsed, overrides: options.overrides)
                 end
      diagnostics = (compiled.is_a?(Array) ? compiled : Array(compiled&.diagnostics)).dup
      if options.grammar
        require_relative "grammar"
        diagnostics.concat(Grammar.diagnostics(read_spec(spec), options.grammar))
      end
      diagnostics.select! do |diagnostic|
        options.warn_level == :all ||
          (options.warn_level == :default && diagnostic.severity != :info && diagnostic.code != "FLEXR-W016")
      end
      diagnostics.concat(emit_shorthand_suggestions(parsed)) if parsed && options.warn_level == :all
      if parsed && options.overrides.fetch(:backend, parsed.config[:backend]) != :firstmatch && options.warn_level != :none
        tables = parsed.config.dig(:options, :keyword_tables)
        diagnostics.concat(Automaton::KeywordTables.grouping_suggestions(compiled, tables))
      end
      diagnostics.concat(Migration.diagnostics(parsed)) if options.target
      set = DiagnosticSet.new
      diagnostics.each { |diagnostic| set << diagnostic }
      if options.format == :json
        out.puts set.render(format: :json)
      elsif !diagnostics.empty?
        out.puts set.render(format: :human, color: options.color, path: spec,
                            source: diagnostic_source(spec, normalize: options.eval_mode))
      end
      return EXIT_FAILURE if options.warn_as_error && diagnostics.any?(&:warning?)

      EXIT_OK
    end

    def emit_shorthand_suggestions(parsed)
      parsed.rules.filter_map do |rule|
        token = rule.emit_shorthand
        next unless token

        Diagnostics.info(
          "FLEXR-I004", "rule emits #{token.inspect} with unchanged matched text",
          location: rule.span, help: "use emit: #{token.inspect} on the rule"
        )
      end
    end

    def print_stats(spec, options, out)
      compiled = compile(read_spec(spec), overrides: options.overrides)
      stats = compiled.stats.transform_keys(&:to_s).transform_values do |stat|
        stat.merge(table_cells: stat[:states] * stat[:classes])
      end
      compiled.machines.each do |state_name, machine|
        dfa = machine.dfa
        stat = stats.fetch(state_name.to_s)
        stat[:table_entries] = dfa.transitions.sum { |row| row.compact.length }
        stat[:acceleration_regions] = Automaton::Accel.extract(dfa).length
      end
      stats[:diagnostics] = Array(compiled.diagnostics).map(&:to_h) if options.format == :json
      out.puts JSON.pretty_generate(stats)
      EXIT_OK
    end

    def print_dot(spec, options, out)
      parsed = read_spec(spec)
      compiled = compile(parsed, overrides: options.overrides)
      out.puts "digraph flexr {"
      labels = keyword_table_labels(parsed.config)
      out.puts "  graph [label=#{dot_quote(labels.join("\n"))}];" unless labels.empty?
      compiled.machines.each do |state_name, machine|
        dfa = machine.dfa
        accelerated_states = Automaton::Accel.extract(dfa).to_h { |region| [region.state, true] }
        dfa.transitions.each_index do |state|
          node_name = "#{state_name}_#{state}"
          node = dot_quote(node_name)
          accepting = !dfa.accepts[state].empty?
          label = dfa.accepts[state].map do |acceptance|
            rule = compiled.rules.fetch(acceptance.rule_index)
            pattern = rule.patterns.fetch(acceptance.pattern_index)
            description = pattern.is_a?(Pattern) ? "#{rule.index} #{pattern.inspect}" : rule.index
            "#{description}#{channel_label(rule)}#{priority_label(rule)}"
          end.uniq.join(",")
          label = "#{node_name}\naccept=#{label}" unless label.empty?
          attributes = dot_node_attributes(label, accepting: accepting, accelerated: accelerated_states[state])
          out.puts "  #{node} [#{attributes}];"
          dfa.transitions[state].compact.uniq.each do |destination|
            out.puts "  #{node} -> #{dot_quote("#{state_name}_#{destination}")};"
          end
        end
      end
      out.puts "}"
      EXIT_OK
    end

    def dot_node_attributes(label, accepting:, accelerated:)
      attributes = { shape: accepting ? "doublecircle" : "circle", label: dot_quote(label) }
      if accepting
        attributes[:color] = dot_quote("#2E7D32")
        attributes[:penwidth] = 2
      end
      if accelerated
        attributes[:color] = dot_quote("#D97706")
        attributes[:style] = "filled"
        attributes[:fillcolor] = dot_quote("#FEF3C7")
      end
      attributes.map { |name, value| "#{name}=#{value}" }.join(", ")
    end

    def dot_quote(value)
      escaped = value.to_s.each_char.with_object(+'') do |character, result|
        result << case character
                  when "\\" then "\\\\"
                  when '"' then '\\"'
                  when "\n" then "\\n"
                  when "\r" then "\\r"
                  else character
                  end
      end
      "\"#{escaped}\""
    end

    def print_trace(spec, options, out, residuals: false)
      parsed = read_spec(spec)
      compiled = compile(parsed, overrides: options.overrides, residuals: residuals)
      out.puts keyword_table_labels(parsed.config)
      compiled.machines.each do |state_name, machine|
        dfa = machine.dfa
        out.puts "state #{state_name} start=#{dfa.start} classes=#{dfa.class_count}"
        dfa.transitions.each_index do |state|
          accepts = dfa.accepts[state].map do |acceptance|
            [acceptance.rule_index, acceptance.pattern_index, acceptance.bol_only, acceptance.end_anchor]
          end
          transitions = dfa.transitions[state].each_with_index.filter_map do |destination, class_id|
            destination && [class_id, destination]
          end
          channels = dfa.accepts[state].map(&:rule_index).uniq.filter_map do |index|
            channel = channel_label(compiled.rules.fetch(index))
            "#{index}#{channel}" if channel
          end
          labels = " channels=[#{channels.join(', ')}]" unless channels.empty?
          labels = "#{labels} residuals=[#{Automaton::DerivativeResiduals.render(machine.residuals.describe(state))}]" if machine.residuals
          out.puts "  #{state}: accepts=#{accepts.inspect} transitions=#{transitions.inspect}#{labels}"
        end
      end
      EXIT_OK
    end

    def print_explanation(spec, options, rule_number, out, residuals: false)
      parsed = read_spec(spec)
      rules = parsed.rules
      rules = rules.select { |rule| rule.index == rule_number } if rule_number
      raise ArgumentError, "rule not found: #{rule_number}" if rules.empty? && rule_number

      compiled = compile(parsed, overrides: options.overrides, residuals: true) if residuals
      out.puts(rules.map { |rule| "rule #{rule.index}#{channel_label(rule)}#{priority_label(rule)}: #{rule.patterns.inspect}" })
      emitted = rules.filter_map do |rule|
        rule.action[1] if !rule.channel && rule.action.is_a?(Array) && rule.action.first == :emit
      end
      out.puts keyword_table_labels(parsed.config, among: emitted)
      print_residuals(compiled, rule_number, out) if compiled
      EXIT_OK
    end

    def print_residuals(compiled, rule_number, out)
      compiled.machines.each do |state_name, machine|
        next unless machine.residuals

        machine.dfa.states.times do |state|
          entries = machine.residuals.describe(state, rule: rule_number)
          next if entries.empty?

          out.puts "state #{state_name} DFA #{state}: #{Automaton::DerivativeResiduals.render(entries)}"
        end
      end
    end

    def channel_label(rule)
      " channel=#{rule.channel.inspect}" if rule.channel
    end

    def priority_label(rule)
      priority = rule.priority.to_i
      priority.zero? ? "" : " (priority #{priority})"
    end

    def keyword_table_labels(config, among: nil)
      config.fetch(:options, {}).fetch(:keyword_tables, {}).filter_map do |type, table|
        next if among && !among.include?(type)

        entries = table.map { |word, (token, _)| "#{word.inspect} => #{token.inspect}" }
        "keywords among #{type.inspect} (#{entries.join(', ')})"
      end
    end

    def print_input_trace(spec, options, trace_args, out)
      require_relative "trace"
      parsed = read_spec(spec)
      source = trace_args[:generated] ? generate(spec, options) : File.read(spec)
      scope = Module.new
      scope.module_eval(source, spec, 1)
      namespace = parsed.class_name.start_with?("::") ? Object : scope
      klass = parsed.class_name.split("::").reject(&:empty?).inject(namespace) { |parent, name| parent.const_get(name, false) }
      unless trace_args[:generated]
        options.overrides.each do |name, value|
          klass.public_send(name, value) if %i[backend token_kind accel].include?(name)
        end
        klass.__flexr_config.options.merge!(options.overrides.slice(:max_dfa_states, :warn_level))
        compiled = klass.compile!
        if options.warn_as_error
          diagnostic = Array(compiled.diagnostics).find do |item|
            item.warning? && (options.warn_level == :all || item.code != "FLEXR-W016")
          end
          raise CompileError.new(diagnostic.message, diagnostic: diagnostic) if diagnostic
        end
      end
      input = trace_args[:input_file] ? File.binread(trace_args[:input_file]) : trace_args.fetch(:input)
      trace = Trace.new(klass.new(input, filename: trace_args[:input_file]), residuals: trace_args[:residuals])
      trace.run
      out.puts(options.format == :json ? JSON.pretty_generate(steps: trace.steps) : trace.render)
      EXIT_OK
    end

    def print_skeleton(spec, options, out, verify:)
      require_relative "skeleton"
      parsed = read_spec(spec)
      compiled = compile(parsed, overrides: options.overrides)
      report = Skeleton.new(compiled, encoding: parsed.config.fetch(:encoding)).report
      if verify
        require_relative "skeleton/verification"
        report[:verification] = Skeleton::Verification.new(
          spec, class_name: parsed.class_name, options: options.generator_options
        ).compare(report.fetch(:cases))
      end
      out.puts(options.format == :json ? JSON.pretty_generate(report) : Skeleton.human(report))
      report.dig(:verification, :mismatches)&.any? ? EXIT_FAILURE : EXIT_OK
    end

    def run_benchmark(spec, options, benchmark_args, out)
      require_relative "../../benchmark/run"
      args = ["--spec", spec, *benchmark_args]
      args << "--json" if options.format == :json
      Flexr::Benchmarking.run(args, out: out, err: $stderr)
    end

    def generate(spec, options)
      Generator.new(spec, eval_mode: options.eval_mode, options: options.generator_options).generate
    end

    def read_spec(spec)
      source = File.binread(spec).force_encoding(Encoding::UTF_8)
      Source::PrismReader.new(source, path: spec).read
    end

    def compile(parsed, overrides: {}, residuals: false)
      klass = Class.new(Flexr::Lexer)
      config = parsed.config
      klass.backend(overrides.fetch(:backend, config.fetch(:backend, :table)))
      klass.token_kind(overrides.fetch(:token_kind, config.fetch(:token_kind, :array)))
      klass.encoding(config.fetch(:encoding, Encoding::UTF_8))
      Array(config[:declared_tokens]).each { |token| klass.emits(token) }
      config_options = config.fetch(:options, {}).merge(overrides.slice(:experimental, :allow_empty_match))
      if (tables = config_options[:keyword_tables])
        klass.__flexr_config.options[:keyword_tables] = tables
      end
      klass.indentation(**config_options[:indentation]) if config_options[:indentation]
      config_options.slice(*Configuration::BOOLEAN_OPTIONS).each do |name, value|
        klass.option(name) if value
      end
      klass.__flexr_config.options[:max_dfa_states] = overrides[:max_dfa_states] if overrides[:max_dfa_states]
      klass.__flexr_config.options[:warn_level] = overrides[:warn_level] if overrides[:warn_level]
      accel = overrides.fetch(:accel, config_options[:accel])
      klass.accel(accel) if accel
      parsed.states.each do |name, value|
        klass.state(name, inclusive: value[:inclusive]) { nil } unless name.to_sym == :initial
        klass.__flexr_states.fetch(name.to_sym).location = value[:location]
      end
      parsed.rules.each { |rule| klass.__flexr_add_generated_rule(rule.to_h) }
      return Automaton::Compiler.new(klass.__flexr_spec, construction: :derivative, retain_residuals: true).compile if residuals

      klass.compile!
    end

    def required_argument!(args, option)
      value = args.shift
      raise ArgumentError, "#{option} requires a value" if value.nil? || value.start_with?("-")

      value
    end

    def diagnostic_source(path, normalize: false, max_bytes: nil)
      return unless path

      source = File.binread(path, max_bytes && (max_bytes + 1))
      return if max_bytes && source.bytesize > max_bytes

      source.force_encoding(Encoding::UTF_8)
      normalize ? source.gsub(/\r\n?/, "\n") : source
    rescue SystemCallError, IOError
      nil
    end

    def render_error(error, options: nil, path: nil, normalize_source: false)
      if error.respond_to?(:diagnostic) && error.diagnostic
        if error.is_a?(LexError) || (error.is_a?(Error) && error.byte_pos)
          path = error.filename
          normalize_source = false
          # shortcut: omit input excerpts above 64 KiB; use bounded line reads if larger inputs need excerpts.
          max_bytes = 64 * 1024
        end
        source = diagnostic_source(path, normalize: normalize_source, max_bytes: max_bytes) if
          error.diagnostic.location && options&.format != :json
        return DiagnosticSet.new.tap { |set| set << error.diagnostic }.render(
          format: options&.format || :human, color: options&.color || :auto, source: source, path: path
        )
      end

      if options&.format == :json
        JSON.generate([{ code: "FLEXR-E000", severity: "error", message: error.message }])
      else
        "error: #{error.message}"
      end
    end

    def version(out)
      out.puts Flexr::VERSION
      EXIT_OK
    end

    def usage(out, status: EXIT_OK)
      out.puts <<~USAGE
        Usage: flexr [COMMAND] SPEC.rb [options]
               flexr new NAME --parser lrama|racc

        Commands: check, fix, stats, tokens, dot, explain, trace, skeleton, bench, import, new
        Options:
          -o, --output PATH          generated output path
          -b, --backend NAME         table | direct | firstmatch | auto
              --token-kind KIND      array | struct | yield
              --accel MODE            auto | strscan | regexp | none
              --standalone
              --eval
              --table-compression VALUE  none | rows | full
              --table-format VALUE       literal | packed
              --max-dfa-states N
          -W, --warn LEVEL           all | default | none
              --warn-as-error
              --color WHEN            auto | always | never
              --format FMT            human | json | lrama (tokens only)
              --grammar PATH          compare emits with grammar %token declarations (check only)
              --input STRING          trace input (executes SPEC actions)
              --input-file PATH       trace or benchmark input
              --generated             trace generated scanner
              --residuals             show remaining DFA expressions (explain or trace)
              --verify                verify skeleton across all modes (executes SPEC actions)
              --target 2.0            report migration requirements (static check only)
              --dry-run               print the fixed spec without writing (fix only)
              --from oedipus_lex      read an oedipus_lex .rex file (import only)
      USAGE
      status
    end
  end
end
