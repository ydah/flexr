# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

RSpec.describe "runtime and generated parity" do
  def repository_root
    File.expand_path("..", __dir__)
  end

  def outcomes_for(source, class_name, inputs)
    Dir.mktmpdir("flexr-parity-") do |directory|
      spec = File.join(directory, "lexer.flexr.rb")
      generated = File.join(directory, "lexer.generated.rb")
      standalone = File.join(directory, "lexer.standalone.rb")
      File.binwrite(spec, source)
      Flexr::Generator.new(spec, output: generated).generate
      Flexr::Generator.new(spec, output: standalone, options: { standalone: true }).generate

      {
        runtime: run_lexer_file(spec, class_name, inputs, load_path: true),
        generated: run_lexer_file(generated, class_name, inputs, load_path: true),
        standalone: run_lexer_file(standalone, class_name, inputs, load_path: false)
      }
    end
  end

  def run_lexer_file(path, class_name, inputs, load_path:)
    script = <<~RUBY
      require "json"
      load ARGV.fetch(0)
      lexer = Object.const_get(ARGV.fetch(1))
      inputs = JSON.parse(ARGV.fetch(2))
      puts JSON.generate(inputs.map { |input| lexer.new(input).tokens })
    RUBY
    command = [RbConfig.ruby]
    command.push("-I", File.join(repository_root, "lib")) if load_path
    command.push("-e", script, path, class_name, JSON.generate(inputs))
    stdout, stderr, status = Open3.capture3(*command)
    expect(status).to be_success, stderr
    JSON.parse(stdout)
  end

  def error_outcomes_for(source, class_name, input)
    Dir.mktmpdir("flexr-error-parity-") do |directory|
      spec = File.join(directory, "lexer.flexr.rb")
      generated = File.join(directory, "lexer.generated.rb")
      standalone = File.join(directory, "lexer.standalone.rb")
      File.binwrite(spec, source)
      Flexr::Generator.new(spec, output: generated).generate
      Flexr::Generator.new(spec, output: standalone, options: { standalone: true }).generate

      {
        runtime: run_error_file(spec, class_name, input, load_path: true),
        generated: run_error_file(generated, class_name, input, load_path: true),
        standalone: run_error_file(standalone, class_name, input, load_path: false)
      }
    end
  end

  def run_error_file(path, class_name, input, load_path:)
    script = <<~RUBY
      require "json"
      load ARGV.fetch(0)
      lexer = Object.const_get(ARGV.fetch(1))
      begin
        lexer.new(ARGV.fetch(2), filename: "input.txt").tokens
        outcome = { kind: "tokens" }
      rescue => error
        outcome = {
          kind: "error", class: error.class.name, message: error.message,
          code: error.respond_to?(:diagnostic) && error.diagnostic&.code,
          filename: error.respond_to?(:filename) && error.filename,
          byte_pos: error.respond_to?(:byte_pos) && error.byte_pos,
          line: error.respond_to?(:line) && error.line,
          text: error.respond_to?(:text) && error.text
        }
      end
      puts JSON.generate(outcome)
    RUBY
    command = [RbConfig.ruby]
    command.push("-I", File.join(repository_root, "lib")) if load_path
    command.push("-e", script, path, class_name, input)
    stdout, stderr, status = Open3.capture3(*command)
    expect(status).to be_success, stderr
    JSON.parse(stdout)
  end

  it "uses skip, emit, block, and default action precedence consistently" do
    source = <<~RUBY
      require "flexr"
      class ActionPrecedenceParityLexer < Flexr::Lexer
        rule(/a/, skip: true) { emit :BLOCK }
        rule(/b/, emit: :OPTION) { emit :BLOCK }
        rule(/c/, skip: false, emit: nil) { emit :BLOCK }
        rule(/d/, skip: false, emit: false) { emit :BLOCK }
        rule(/e/, emit: :OPTION)
        rule(/f/)
      end
    RUBY

    outcomes = outcomes_for(source, "ActionPrecedenceParityLexer", ["abcdef"])
    expect(outcomes.values.uniq.one?).to be(true), outcomes.inspect
    expect(outcomes[:runtime]).to eq([[%w[OPTION b], %w[BLOCK c], %w[BLOCK d],
                                      %w[OPTION e], [nil, "f"]]])
  end

  it "preserves nested state membership and separate state-local bindings" do
    source = <<~RUBY
      require "flexr"
      class StateScopeParityLexer < Flexr::Lexer
        rule(/1/) { begin_state :outer; skip }
        rule(/2/) { begin_state :second; skip }
        state :outer do
          value = :OUTER
          state :inner do
            rule(/a/) { emit :NESTED, value }
          end
          rule(/b/) { emit :OUTER, value }
        end
        state :second do
          value = :SECOND
          rule(/a/) { emit :SECOND, value }
        end
      end
    RUBY

    outcomes = outcomes_for(source, "StateScopeParityLexer", %w[1ab 2a])
    expect(outcomes.values.uniq.one?).to be(true), outcomes.inspect
    expect(outcomes[:runtime]).to eq([
      [%w[NESTED OUTER], %w[OUTER OUTER]],
      [%w[SECOND SECOND]]
    ])
  end

  it "rejects every specification mutation after compilation" do
    lexer = Class.new(Flexr::Lexer) { rule(/a/) { emit :A } }
    compiled = lexer.compile!
    mutations = [
      -> { lexer.rule(/b/) },
      -> { lexer.state(:other) { nil } },
      -> { lexer.on_eof { nil } },
      -> { lexer.emits(:A) },
      -> { lexer.backend(:direct) },
      -> { lexer.token_kind(:struct) },
      -> { lexer.encoding(Encoding::BINARY) },
      -> { lexer.option(:unicode) },
      -> { lexer.accel(:none) }
    ]

    mutations.each { |mutation| expect(&mutation).to raise_error(Flexr::FrozenSpecificationError) }
    expect { lexer.__flexr_config.options[:unicode] = true }.to raise_error(FrozenError)
    dfa = compiled.machines.fetch(:initial).dfa
    expect(dfa).to be_frozen
    expect { dfa.transitions.first[0] = 1 }.to raise_error(FrozenError)
  end

  it "validates runtime configuration and conflicting state declarations immediately" do
    expect { Class.new(Flexr::Lexer).backend(:tabel) }.to raise_error(ArgumentError, /backend/)
    expect { Class.new(Flexr::Lexer).accel(:strsacn) }.to raise_error(ArgumentError, /accel/)
    expect { Class.new(Flexr::Lexer).option(:unicdoe) }.to raise_error(ArgumentError, /option/)
    lexer = Class.new(Flexr::Lexer)
    lexer.state(:word, inclusive: true) { nil }
    expect { lexer.state(:word, inclusive: false) { nil } }.to raise_error(ArgumentError, /already declared/)
  end

  it "does not let user constants shadow generated Regexp and StringScanner references" do
    source = <<~RUBY
      require "flexr"
      class ConstantShadowParityLexer < Flexr::Lexer
        Regexp = Object.new
        StringScanner = Object.new
        rule(/a+/) { emit :A }
      end
    RUBY

    outcomes = outcomes_for(source, "ConstantShadowParityLexer", ["aaa"])
    expect(outcomes.values.uniq.one?).to be(true), outcomes.inspect
    expect(outcomes[:generated]).to eq([[%w[A aaa]]])
  end

  it "returns the same structured error outcome in every mode" do
    source = <<~RUBY
      require "flexr"
      class ErrorOutcomeParityLexer < Flexr::Lexer
        rule(/a/) { emit :A }
      end
    RUBY

    outcomes = error_outcomes_for(source, "ErrorOutcomeParityLexer", "x")
    expect(outcomes.values.uniq.one?).to be(true), outcomes.inspect
    expect(outcomes[:runtime]).to include(
      "kind" => "error", "class" => "Flexr::LexError", "filename" => "input.txt",
      "byte_pos" => 0, "line" => 1, "text" => "x"
    )
  end
end
