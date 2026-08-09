# frozen_string_literal: true

module Flexr
  module CLI
    module_function

    def run(argv, out: $stdout, err: $stderr)
      return usage(out) if argv.include?("--help") || argv.include?("-h")

      command = %w[check stats tokens dot explain trace import].include?(argv.first) ? argv.shift : nil
      command ||= :generate
      options = Options.default
      spec = argv.shift
      return usage(out) unless spec

      output = nil
      while (argument = argv.shift)
        case argument
        when "-o", "--output" then output = argv.shift
        when "--eval" then options.eval_mode = true
        when "-b", "--backend" then options.backend = argv.shift.to_sym
        when "--token-kind" then options.token_kind = argv.shift.to_sym
        when "--format" then options.format = argv.shift.to_sym
        when "--warn-as-error" then options.warn_as_error = true
        end
      end
      case command.to_sym
      when :check
        Generator.new(spec, eval_mode: options.eval_mode).generate
        0
      when :stats
        parsed = Source::PrismReader.new(File.read(spec), path: spec).read
        klass = Class.new(Flexr::Lexer)
        parsed.states.each { |name, value| klass.state(name, inclusive: value[:inclusive]) { } unless name == :initial }
        parsed.rules.each do |rule|
          klass.__flexr_add_generated_rule(index: rule.index, patterns: rule.patterns, trailing: rule.trailing,
                                            action: :skip, states: rule.states)
        end
        compiled = klass.compile!
        out.puts JSON.pretty_generate(compiled.stats)
        0
      when :tokens
        generated = Source::PrismReader.new(File.read(spec), path: spec).read
        out.puts generated.config[:declared_tokens].join(" ")
        0
      when :dot
        parsed = Source::PrismReader.new(File.read(spec), path: spec).read
        klass = Class.new(Flexr::Lexer)
        parsed.states.each { |name, value| klass.state(name, inclusive: value[:inclusive]) { } unless name == :initial }
        parsed.rules.each { |rule| klass.__flexr_add_generated_rule(index: rule.index, patterns: rule.patterns, action: :skip, states: rule.states) }
        dfa = klass.compile!.machines.fetch(:initial).dfa
        out.puts "digraph flexr {"
        dfa.transitions.each_index do |state|
          out.puts "  #{state} [shape=#{dfa.accepts[state].empty? ? "circle" : "doublecircle"}];"
          dfa.transitions[state].compact.uniq.each { |destination| out.puts "  #{state} -> #{destination};" }
        end
        out.puts "}"
        0
      when :explain
        parsed = Source::PrismReader.new(File.read(spec), path: spec).read
        out.puts parsed.rules.map { |rule| "rule #{rule.index}: #{rule.patterns.inspect}" }
        0
      when :trace
        generated = Generator.new(spec, output: nil, eval_mode: options.eval_mode).generate
        out.puts generated
        0
      when :import
        out.puts "# FLEXR-TODO: import requires manual action translation"
        out.puts "require \"flexr\""
        out.puts "class Lexer < Flexr::Lexer; end"
        0
      when :generate
        output ||= spec.sub(/\.flexr\.rb\z/, ".rb")
        Generator.new(spec, output: output, eval_mode: options.eval_mode,
                      options: { backend: options.backend, token_kind: options.token_kind }).generate
        0
      else
        err.puts "unknown command: #{command}"
        2
      end
    rescue Flexr::Error => error
      err.puts error.diagnostic ? DiagnosticSet.new.tap { |set| set << error.diagnostic }.render : error.message
      1
    end

    def usage(out)
      out.puts "Usage: flexr [check|stats|tokens] SPEC.rb [-o OUTPUT] [--eval]"
      0
    end
  end
end
