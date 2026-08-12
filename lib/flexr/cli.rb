# frozen_string_literal: true

require_relative "runtime" unless defined?(Flexr::Lexer)
require_relative "artifact_writer"
require_relative "generator"
require_relative "importer"
require_relative "options"

module Flexr
  module CLI
    COMMANDS = %w[check stats tokens dot explain trace bench import].freeze
    EXIT_OK = 0
    EXIT_FAILURE = 1
    EXIT_USAGE = 2

    module_function

    def run(argv, out: $stdout, err: $stderr)
      args = argv.dup
      return usage(out) if args.include?("--help") || args.include?("-h")
      return version(out) if args.delete("--version")

      command = COMMANDS.include?(args.first) ? args.shift.to_sym : :generate
      options, output, rule_number, benchmark_args, positionals = parse(args, command)
      spec = positionals.shift
      raise ArgumentError, "a SPEC.rb path is required" unless spec
      raise ArgumentError, "unexpected argument: #{positionals.first}" unless positionals.empty?

      execute(command, spec, options, output, rule_number, benchmark_args, out, err)
    rescue ArgumentError => e
      err.puts "error: #{e.message}"
      usage(err, status: EXIT_USAGE)
    rescue Flexr::Error, Errno::ENOENT, Errno::EACCES, SyntaxError => e
      err.puts render_error(e, options: options)
      EXIT_FAILURE
    rescue StandardError => e
      err.puts "error: #{e.class}: #{e.message}"
      EXIT_FAILURE
    end

    def parse(args, command)
      options = Options.default
      output = nil
      rule_number = nil
      benchmark_args = []
      positionals = []
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
          options.eval_mode = true
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
        when "--rule"
          rule_number = Integer(required_argument!(args, argument), 10)
          raise ArgumentError, "--rule must be non-negative" if rule_number.negative?
        when "--input-file", "--baseline", "--iterations"
          raise ArgumentError, "#{argument} is only valid for the bench command" unless command == :bench
          benchmark_args.push(argument, required_argument!(args, argument))
        else
          raise ArgumentError, "unknown option: #{argument}"
        end
      end

      options.validate!
      [options, output, rule_number, benchmark_args, positionals]
    rescue ArgumentError => e
      raise e if e.message.start_with?("unsupported ", "--rule")

      raise ArgumentError, "invalid option value: #{e.message}"
    end

    def execute(command, spec, options, output, rule_number, benchmark_args, out, err)
      case command
      when :check
        check(spec, options, out)
      when :stats
        print_stats(spec, options, out)
      when :tokens
        parsed = read_spec(spec)
        out.puts Array(parsed.config[:declared_tokens]).join(" ")
        EXIT_OK
      when :dot
        print_dot(spec, options, out)
      when :explain
        print_explanation(spec, rule_number, out)
      when :trace
        print_trace(spec, options, out)
      when :bench
        run_benchmark(spec, options, benchmark_args, out)
      when :import
        result = Importer.import(spec)
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

    def check(spec, options, out)
      compiled = if options.eval_mode
                   generator = Generator.new(spec, eval_mode: true, options: options.generator_options)
                   generator.generate
                   generator.diagnostics
                 else
                   compile(read_spec(spec), overrides: options.overrides)
                 end
      diagnostics = (compiled.is_a?(Array) ? compiled : Array(compiled&.diagnostics)).dup
      diagnostics.select! do |diagnostic|
        options.warn_level == :all || (options.warn_level == :default && diagnostic.code != "FLEXR-W016")
      end
      set = DiagnosticSet.new
      diagnostics.each { |diagnostic| set << diagnostic }
      if options.format == :json
        out.puts set.render(format: :json)
      elsif !diagnostics.empty?
        out.puts set.render(format: :human, color: options.color)
      end
      return EXIT_FAILURE if options.warn_as_error && diagnostics.any?(&:warning?)

      EXIT_OK
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
      compiled = compile(read_spec(spec), overrides: options.overrides)
      out.puts "digraph flexr {"
      compiled.machines.each do |state_name, machine|
        dfa = machine.dfa
        accelerated_states = Automaton::Accel.extract(dfa).to_h { |region| [region.state, true] }
        dfa.transitions.each_index do |state|
          node_name = "#{state_name}_#{state}"
          node = dot_quote(node_name)
          accepting = !dfa.accepts[state].empty?
          label = dfa.accepts[state].map(&:rule_index).uniq.join(",")
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

    def print_trace(spec, options, out)
      compiled = compile(read_spec(spec), overrides: options.overrides)
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
          out.puts "  #{state}: accepts=#{accepts.inspect} transitions=#{transitions.inspect}"
        end
      end
      EXIT_OK
    end

    def print_explanation(spec, rule_number, out)
      rules = read_spec(spec).rules
      rules = rules.select { |rule| rule.index == rule_number } if rule_number
      raise ArgumentError, "rule not found: #{rule_number}" if rules.empty? && rule_number

      out.puts(rules.map { |rule| "rule #{rule.index}: #{rule.patterns.inspect}" })
      EXIT_OK
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

    def compile(parsed, overrides: {})
      klass = Class.new(Flexr::Lexer)
      config = parsed.config
      klass.backend(overrides.fetch(:backend, config.fetch(:backend, :table)))
      klass.token_kind(overrides.fetch(:token_kind, config.fetch(:token_kind, :array)))
      klass.encoding(config.fetch(:encoding, Encoding::UTF_8))
      Array(config[:declared_tokens]).each { |token| klass.emits(token) }
      config_options = config.fetch(:options, {}).merge(overrides.slice(:experimental, :allow_empty_match))
      config_options.slice(*Configuration::BOOLEAN_OPTIONS).each do |name, value|
        klass.option(name) if value
      end
      klass.__flexr_config.options[:max_dfa_states] = overrides[:max_dfa_states] if overrides[:max_dfa_states]
      accel = overrides.fetch(:accel, config_options[:accel])
      klass.accel(accel) if accel
      parsed.states.each do |name, value|
        next if name.to_sym == :initial

        klass.state(name, inclusive: value[:inclusive]) { nil }
      end
      parsed.rules.each { |rule| klass.__flexr_add_generated_rule(rule.to_h) }
      klass.compile!
    end

    def required_argument!(args, option)
      value = args.shift
      raise ArgumentError, "#{option} requires a value" if value.nil? || value.start_with?("-")

      value
    end

    def render_error(error, options: nil)
      if error.respond_to?(:diagnostic) && error.diagnostic
        return DiagnosticSet.new.tap { |set| set << error.diagnostic }.render(
          format: options&.format || :human, color: options&.color || :auto
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

        Commands: check, stats, tokens, dot, explain, trace, bench, import
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
              --format FMT            human | json
      USAGE
      status
    end
  end
end
