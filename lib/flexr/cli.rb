# frozen_string_literal: true

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
          options.backend = required_argument!(args, argument).to_sym
        when "--token-kind"
          options.token_kind = required_argument!(args, argument).to_sym
        when "--accel"
          options.accel = required_argument!(args, argument).to_sym
        when "--standalone"
          options.standalone = true
        when "--eval"
          options.eval_mode = true
        when "--table-compression"
          options.table_compression = required_argument!(args, argument).to_sym
        when "--table-format"
          options.table_format = required_argument!(args, argument).to_sym
        when "--max-dfa-states"
          options.max_dfa_states = Integer(required_argument!(args, argument), 10)
        when "-W", "--warn"
          options.warn_level = required_argument!(args, argument).to_sym
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
        out.write generate(spec, options)
        EXIT_OK
      when :bench
        run_benchmark(spec, options, benchmark_args, out)
      when :import
        result = Importer.import(spec)
        if output
          File.binwrite(output, result.source)
        else
          out.write(result.source)
        end
        result.warnings.each { |warning| err.puts "warning: #{warning}" }
        result.complete? ? EXIT_OK : EXIT_FAILURE
      when :generate
        target = output || spec.sub(/\.flexr\.rb\z/, ".rb")
        Generator.new(spec, output: target, eval_mode: options.eval_mode,
                      options: options.generator_options).generate
        EXIT_OK
      end
    end

    def check(spec, options, out)
      if options.eval_mode
        generate(spec, options)
      else
        compile(read_spec(spec))
      end
      out.puts "[]" if options.format == :json
      EXIT_OK
    end

    def print_stats(spec, _options, out)
      out.puts JSON.pretty_generate(compile(read_spec(spec)).stats)
      EXIT_OK
    end

    def print_dot(spec, _options, out)
      dfa = compile(read_spec(spec)).machines.fetch(:initial).dfa
      out.puts "digraph flexr {"
      dfa.transitions.each_index do |state|
        shape = dfa.accepts[state].empty? ? "circle" : "doublecircle"
        out.puts "  #{state} [shape=#{shape}];"
        dfa.transitions[state].compact.uniq.each { |destination| out.puts "  #{state} -> #{destination};" }
      end
      out.puts "}"
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

    def compile(parsed)
      klass = Class.new(Flexr::Lexer)
      config = parsed.config
      klass.backend(config.fetch(:backend, :table))
      klass.token_kind(config.fetch(:token_kind, :array))
      klass.encoding(config.fetch(:encoding, Encoding::UTF_8))
      config.fetch(:options, {}).each do |name, value|
        value ? klass.option(name) : nil
      end
      klass.accel(config[:options][:accel]) if config.fetch(:options, {}).key?(:accel)
      parsed.states.each do |name, value|
        next if name.to_sym == :initial

        klass.state(name, inclusive: value[:inclusive]) { nil }
      end
      parsed.rules.each { |rule| klass.__flexr_add_generated_rule(rule.to_h.merge(action: :skip)) }
      klass.compile!
    end

    def required_argument!(args, option)
      value = args.shift
      raise ArgumentError, "#{option} requires a value" if value.nil? || value.start_with?("-")

      value
    end

    def render_error(error, options: nil)
      return DiagnosticSet.new.tap { |set| set << error.diagnostic }.render(format: options&.format || :human) if error.respond_to?(:diagnostic) && error.diagnostic

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
