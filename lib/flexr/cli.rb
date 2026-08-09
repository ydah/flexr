# frozen_string_literal: true

module Flexr
  module CLI
    module_function

    def run(argv, out: $stdout, err: $stderr)
      command = %w[check stats tokens].include?(argv.first) ? argv.shift : nil
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
        generated = Generator.new(spec, eval_mode: options.eval_mode).generate
        out.puts generated[/states: \d+/] || "states: unknown"
        0
      when :tokens
        generated = Source::PrismReader.new(File.read(spec), path: spec).read
        out.puts generated.config[:declared_tokens].join(" ")
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
