# frozen_string_literal: true

require_relative "run"
require_relative "../lib/flexr/cli"

module Flexr
  module Benchmarking
    module StateDispatch
      module_function

      def lexers(path)
        parsed = CLI.read_spec(path)
        compiled = CLI.compile(parsed, overrides: { backend: :table })
        indent = Source::Passthrough.indentation(parsed.source, parsed.first_dsl_offset)
        scanner = Codegen::Table.new(compiled).source(indent: indent)
        replacement = scanner.gsub("dfa.transition(current, byte)", "__flexr_state_transition(current, ec[byte])")
        raise "generated scanner has no table dispatch" if replacement == scanner

        replacement += dispatch_source(compiled, indent)
        generated = Generator.new(path, options: { backend: :table }).generate
        raise "generated scanner template changed" unless generated.include?(scanner)

        [generated, Generator.new(path, options: { backend: :direct }).generate,
         generated.sub(scanner, replacement)].map do |source|
          scope = Module.new
          scope.module_eval(source, path)
          parsed.class_name.split("::").reject(&:empty?).inject(scope) { |parent, name| parent.const_get(name, false) }
        end
      end

      def dispatch_source(compiled, indent)
        lines = ["def __flexr_state_transition(state, class_id)", "case @state"]
        compiled.machines.each do |name, machine|
          lines << "when #{name.inspect}" << "case state"
          machine.dfa.transitions.each_with_index do |row, state|
            if row.compact.empty?
              lines << "when #{state} then nil"
              next
            end
            lines << "when #{state}" << "case class_id"
            row.each_with_index.group_by(&:first).each do |destination, pairs|
              next unless destination

              lines << "when #{pairs.map(&:last).join(', ')} then #{destination}"
            end
            lines << "else nil" << "end"
          end
          lines << "else nil" << "end"
        end
        (lines + ["else nil", "end", "end"]).map { |line| "#{indent}#{line}\n" }.join
      end

      def run(argv, out: $stdout)
        options = Benchmarking.parse(argv.dup)
        return Benchmarking.usage(out) if options[:help]
        raise ArgumentError, "--baseline and --write-baseline do not apply to this experiment" if options[:baseline] || options[:write_baseline]

        path = File.expand_path(options.fetch(:spec))
        input = options[:input_file] ? File.binread(options[:input_file]) : Benchmarking::DEFAULT_INPUTS.find { |pattern, _| path.match?(pattern) }&.last
        raise ArgumentError, "--input-file is required for this spec" unless input

        table, direct, switched = lexers(path)
        expected = table.new(input).tokens
        raise "state dispatch changed tokens" unless [direct, switched].all? { |lexer| lexer.new(input).tokens == expected }

        runner = Runner.new(options)
        result = { ruby: RUBY_DESCRIPTION, input_bytes: input.bytesize, iterations: options[:iterations],
                   modes: { table: runner.send(:measure_class, table, input),
                            direct: runner.send(:measure_class, direct, input),
                            state_cases: runner.send(:measure_class, switched, input) } }
        out.puts JSON.pretty_generate(result)
        result
      end
    end
  end
end

Flexr::Benchmarking::StateDispatch.run(ARGV) if $PROGRAM_NAME == __FILE__
