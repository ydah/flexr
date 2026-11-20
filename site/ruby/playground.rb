# frozen_string_literal: true

require "stringio"

module FlexrPlayground
  module_function

  def run(request)
    path = "/playground.flexr.rb"
    source = request.fetch("source")
    File.write(path, source)
    stdout = $stdout
    stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    options = Flexr::Options.default
    options.set(:max_dfa_states, 1024)
    options.set(:warn_level, :all)
    options.color = :never
    diagnostics = StringIO.new
    Flexr::CLI.check(path, options, diagnostics)
    generated = Flexr::Generator.new(path, options: options.generator_options).generate
    parsed = Flexr::CLI.read_spec(path)
    scope = Module.new
    scope.module_eval(request["mode"] == "generated" ? generated : source, path, 1)
    namespace = parsed.class_name.start_with?("::") ? Object : scope
    klass = parsed.class_name.split("::").reject(&:empty?).inject(namespace) { |parent, name| parent.const_get(name, false) }
    unless request["mode"] == "generated"
      klass.__flexr_config.options[:max_dfa_states] = 1024
      klass.__flexr_config.options[:warn_level] = :all
    end
    input_path = "/input.txt"
    File.write(input_path, request.fetch("input"))
    lexer = klass.new(request.fetch("input"), filename: input_path, max_steps: 1_000_000, max_token_size: 65_536,
                      max_lookahead_size: 65_536, max_buffer_size: 1_048_576)
    trace = Flexr::Trace.new(lexer)
    tokens = trace.run
    dot = StringIO.new
    Flexr::CLI.print_dot(path, options, dot)
    JSON.generate(tokens: tokens, steps: trace.steps, diagnostics: diagnostics.string,
                  generated: generated, dot: dot.string, ruby_version: RUBY_VERSION,
                  prism_version: Prism::VERSION,
                  console: ($stdout.string + $stderr.string).byteslice(0, 4096).force_encoding(Encoding::UTF_8).scrub)
  rescue StandardError, SyntaxError, LoadError, SystemExit => e
    if e.is_a?(Flexr::LexError) && !e.diagnostic && e.byte_pos
      diagnostic = Flexr::Diagnostics.error("FLEXR-E000", e.message,
                                           location: [e.byte_pos, e.byte_pos + e.text.to_s.bytesize])
      e = Flexr::LexError.new(e.message, diagnostic: diagnostic,
                             filename: e.filename, byte_pos: e.byte_pos, line: e.line, text: e.text)
    end
    JSON.generate(error: Flexr::CLI.render_error(e, options: options, path: path),
                  ruby_version: RUBY_VERSION, prism_version: defined?(Prism::VERSION) && Prism::VERSION)
  ensure
    $stdout = stdout
    $stderr = stderr
  end
end
