# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "flexr/trace"

RSpec.describe "runtime and generated parity" do
  def repository_root
    File.expand_path("..", __dir__)
  end

  def outcomes_for(source, class_name, inputs, streaming: false)
    Dir.mktmpdir("flexr-parity-") do |directory|
      spec = File.join(directory, "lexer.flexr.rb")
      generated = File.join(directory, "lexer.generated.rb")
      standalone = File.join(directory, "lexer.standalone.rb")
      File.binwrite(spec, source)
      Flexr::Generator.new(spec, output: generated).generate
      Flexr::Generator.new(spec, output: standalone, options: { standalone: true }).generate

      {
        runtime: run_lexer_file(spec, class_name, inputs, load_path: true, streaming: streaming),
        generated: run_lexer_file(generated, class_name, inputs, load_path: true, streaming: streaming),
        standalone: run_lexer_file(standalone, class_name, inputs, load_path: false, streaming: streaming)
      }
    end
  end

  def run_lexer_file(path, class_name, inputs, load_path:, streaming:)
    script = <<~RUBY
      require "json"
      require "stringio"
      load ARGV.fetch(0)
      lexer = Object.const_get(ARGV.fetch(1))
      inputs = JSON.parse(ARGV.fetch(2))
      tokens = inputs.map do |input|
        if #{streaming}
          lexer.new(StringIO.new(input), chunk_size: 1, retain_input: false).tokens
        else
          lexer.new(input).tokens
        end
      end
      puts JSON.generate(tokens)
    RUBY
    command = [RbConfig.ruby]
    command.push("-I", File.join(repository_root, "lib")) if load_path
    command.push("-e", script, path, class_name, JSON.generate(inputs))
    stdout, stderr, status = Open3.capture3(*command)
    expect(status).to be_success, stderr
    JSON.parse(stdout)
  end

  def error_outcomes_for(source, class_name, input, options: {})
    Dir.mktmpdir("flexr-error-parity-") do |directory|
      spec = File.join(directory, "lexer.flexr.rb")
      generated = File.join(directory, "lexer.generated.rb")
      standalone = File.join(directory, "lexer.standalone.rb")
      File.binwrite(spec, source)
      Flexr::Generator.new(spec, output: generated).generate
      Flexr::Generator.new(spec, output: standalone, options: { standalone: true }).generate

      {
        runtime: run_error_file(spec, class_name, input, options: options, load_path: true),
        generated: run_error_file(generated, class_name, input, options: options, load_path: true),
        standalone: run_error_file(standalone, class_name, input, options: options, load_path: false)
      }
    end
  end

  def run_error_file(path, class_name, input, options:, load_path:)
    script = <<~RUBY
      require "json"
      load ARGV.fetch(0)
      lexer = Object.const_get(ARGV.fetch(1))
      begin
        lexer.new(JSON.parse(ARGV.fetch(2)), filename: "input.txt", **JSON.parse(ARGV.fetch(3), symbolize_names: true)).tokens
        outcome = { kind: "tokens" }
      rescue => error
        outcome = {
          kind: "error", class: error.class.name, message: error.message,
          code: error.respond_to?(:diagnostic) && error.diagnostic&.code,
          location: error.respond_to?(:diagnostic) && error.diagnostic&.location,
          note: error.respond_to?(:diagnostic) && error.diagnostic&.note,
          rule: error.respond_to?(:rule) && error.rule,
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
    command.push("-e", script, path, class_name, JSON.generate(input), JSON.generate(options))
    stdout, stderr, status = Open3.capture3(*command)
    expect(status).to be_success, stderr
    JSON.parse(stdout)
  end

  it "preserves runtime guard input locations in generated and standalone scanners" do
    source = <<~'RUBY'
      require "flexr"
      class GuardLocationParityLexer < Flexr::Lexer
        rule(/é|\n/, skip: true)
        rule(/a/) { less(0) }
      end
    RUBY

    outcomes = error_outcomes_for(source, "GuardLocationParityLexer", "é\néa")

    expect(outcomes.values.uniq.one?).to be(true), outcomes.inspect
    expect(outcomes[:runtime]).to include("code" => "FLEXR-E021", "byte_pos" => 5, "location" => [5, 5],
                                          "note" => "rule /a/", "rule" => 1)
  end

  it "scans octal byte escapes in runtime, generated, and standalone lexers" do
    source = <<~'RUBY'
      require "flexr"
      class OctalParityLexer < Flexr::Lexer
        rule(/[\011\015]+/, skip: true)
        rule(/\303\xA9+/) { emit :LETTER, text.bytes }
        rule(/\08|\1234/, emit: :ESCAPE)
      end
    RUBY
    input = "\x008\téé\rS4"
    expected = [[["ESCAPE", "\x008"], ["LETTER", "éé".bytes], ["ESCAPE", "S4"]]]
    expect(outcomes_for(source, "OctalParityLexer", [input], streaming: true).values).to all(eq(expected))
  end

  %i[table direct auto].each do |backend|
    it "ends absence comments at the first close in every #{backend} scanner" do
      source = <<~'RUBY'.sub("BACKEND", backend.to_s)
        require "flexr"
        class AbsenceParityLexer < Flexr::Lexer
          backend :BACKEND
          accel :strscan
          rule(%r{/\*(?~\*/)\*/}, emit: :COMMENT)
          rule(/./m, emit: :OTHER)
        end
      RUBY
      input = "/*é\n***/x/**/"
      expected = [[["COMMENT", "/*é\n***/"], ["OTHER", "x"], ["COMMENT", "/**/"]]]
      expect(outcomes_for(source, "AbsenceParityLexer", [input]).values).to all(eq(expected))
    end

    it "uses explicit priority only for equal-length matches in #{backend}" do
      source = <<~RUBY
        require "flexr"
        class PriorityLexer < Flexr::Lexer
          backend :#{backend}
          rule(/[a-z]+/, emit: :IDENT)
          rule("if", emit: :IF, priority: 10)
          rule("if", emit: :LATER, priority: 10)
          rule(" ", skip: true)
        end
      RUBY

      expected = [[%w[IF if], %w[IDENT ifx]]]
      expect(outcomes_for(source, "PriorityLexer", ["if ifx"]).values).to all(eq(expected))
    end
  end

  it "uses priority to break ties that include trailing lookahead" do
    source = <<~RUBY
      require "flexr"
      class TrailingPriorityLexer < Flexr::Lexer
        rule("ab", followed_by: "c", emit: :LOW)
        rule("a", followed_by: "bc", emit: :HIGH, priority: 10)
        rule(/[abc]/, emit: :CHAR)
      end
    RUBY

    expected = [[%w[HIGH a], %w[CHAR b], %w[CHAR c]]]
    expect(outcomes_for(source, "TrailingPriorityLexer", ["abc"]).values).to all(eq(expected))
  end

  it "explains priority in shadowing diagnostics and the input trace" do
    source = <<~RUBY
      class PriorityDiagnosticLexer < Flexr::Lexer
        rule("if", emit: :LOW, priority: -1)
        rule("if", emit: :HIGH, priority: 10)
      end
    RUBY
    parsed = Flexr::Source::PrismReader.new(source).read
    diagnostics = Flexr::CLI.compile(parsed, overrides: { warn_level: :all }).diagnostics
    %w[FLEXR-W001 FLEXR-I001].each do |code|
      diagnostic = diagnostics.find { |item| item.code == code }
      expect(diagnostic.note).to include('"if"', "priority 10")
    end

    lexer = Class.new(Flexr::Lexer) do
      rule("if", emit: :LOW, priority: -1)
      rule("if", emit: :HIGH, priority: 10)
    end
    trace = Flexr::Trace.new(lexer.new("if"))
    expect(trace.run).to eq([[:HIGH, "if"]])
    expect(trace.steps.first).to include(reason: "priority")
    expect(trace.steps.first.fetch(:candidates)).to include(a_hash_including(rule: 1, priority: 10))
  end

  it "reports source order when several highest-priority matches tie" do
    lexer = Class.new(Flexr::Lexer) do
      rule("if", emit: :LOW)
      rule("if", emit: :HIGH, priority: 10)
      rule("if", emit: :LATER, priority: 10)
    end
    trace = Flexr::Trace.new(lexer.new("if"))
    expect(trace.run).to eq([[:HIGH, "if"]])
    expect(trace.steps.first.fetch(:reason)).to eq("rule_order")
  end

  it "rejects an artifact that requires unavailable priority or channel support" do
    Dir.mktmpdir do |directory|
      source = File.join(directory, "lexer.flexr.rb")
      generated = File.join(directory, "lexer.generated.rb")
      File.write(source, <<~RUBY)
        require "flexr"
        class ABI2PriorityLexer < Flexr::Lexer
          rule("if", channel: :comment, emit: :IF, priority: 10)
        end
      RUBY
      Flexr::Generator.new(source, output: generated).generate
      script = <<~RUBY
        require "flexr"
        case ARGV.fetch(1)
        when "explicit rule priority"
          Flexr::IR::Rule.send(:remove_method, :loses_priority_tie?)
        when "token channels"
          Flexr::Runtime.send(:remove_const, :Channels)
        end
        begin
          load ARGV.fetch(0)
        rescue Flexr::CompileError => error
          puts error.diagnostic.code
          puts error.diagnostic.note
        end
      RUBY
      ["explicit rule priority", "token channels"].each do |capability|
        output, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script, generated, capability)
        expect(status).to be_success, stderr
        expect(output).to include("FLEXR-E020", "runtime does not support #{capability}")
      end
    end
  end

  it "uses the compiled absence language for trailing context in all modes" do
    source = <<~RUBY
      require "flexr"
      class AbsenceTrailingLexer < Flexr::Lexer
        backend :firstmatch
        rule("x", followed_by: /y(?~ab)ab/, emit: :X)
        rule(/./m, emit: :OTHER)
      end
    RUBY
    input = "xyab"
    expected = [[%w[X x], %w[OTHER y], %w[OTHER a], %w[OTHER b]]]
    expect(outcomes_for(source, "AbsenceTrailingLexer", [input]).values).to all(eq(expected))
  end

  it "runs static pattern algebra with identical longest matches in all modes" do
    source = <<~RUBY
      require "flexr"
      class AlgebraParityLexer < Flexr::Lexer
        IDENT = pattern(/[a-z]+/)
        KEYWORD = pattern(%w[if else])
        TERMINATED = upto("aba")
        rule(KEYWORD, emit: :KEYWORD)
        rule(IDENT - KEYWORD, emit: :IDENT)
        rule(pattern("<") + TERMINATED, emit: :SEGMENT)
        rule("!", followed_by: TERMINATED, emit: :LOOKAHEAD)
        rule(/ +/, skip: true)
      end
    RUBY
    input = "if ify <éababa !aba"
    expected = [[%w[KEYWORD if], %w[IDENT ify], %w[SEGMENT <éaba], %w[IDENT ba], %w[LOOKAHEAD !], %w[IDENT aba]]]

    expect(outcomes_for(source, "AlgebraParityLexer", [input]).values).to all(eq(expected))
  end

  { "UTF_8" => "OTHER", "BINARY" => "BYTE" }.each do |encoding, byte_token|
    it "respects trailing absence anchors and boundaries in streaming #{encoding}" do
      source = <<~'RUBY'.sub("INPUT_ENCODING", encoding)
        require "flexr"
        class AbsenceTrailingBoundaryLexer < Flexr::Lexer
          encoding Encoding::INPUT_ENCODING
          rule("x", followed_by: /^y(?~ab)ab/, emit: :ANCHOR)
          rule("x\n", followed_by: /^y(?~ab)ab/, emit: :ANCHOR)
          rule("x", followed_by: /y(?~ab)\xC3/n, emit: :BYTE)
          rule(/\xC3\xA9/n, skip: true)
          rule(/./m, emit: :OTHER)
        end
      RUBY
      inputs = %W[xyab x\nyab xyé]
      expected = [
        [%w[OTHER x], %w[OTHER y], %w[OTHER a], %w[OTHER b]],
        [%W[ANCHOR x\n], %w[OTHER y], %w[OTHER a], %w[OTHER b]],
        [[byte_token, "x"], %w[OTHER y]]
      ]

      outcomes = outcomes_for(source, "AbsenceTrailingBoundaryLexer", inputs, streaming: true)
      expect(outcomes.values).to all(eq(expected))
    end
  end

  %i[table direct firstmatch].each do |backend|
    it "preserves trailing-context lookahead errors in every #{backend} mode" do
      source = <<~RUBY
        require "flexr"
        class TrailingGuardParityLexer < Flexr::Lexer
          backend :#{backend}
          option :experimental
          rule(/a/, followed_by: /b+/, skip: true)
        end
      RUBY

      outcomes = error_outcomes_for(source, "TrailingGuardParityLexer", "abbbb", options: { max_lookahead_size: 2 })

      expect(outcomes.values.uniq.one?).to be(true), outcomes.inspect
      expect(outcomes[:runtime]).to include("code" => "FLEXR-E024", "rule" => 0, "byte_pos" => 0,
                                            "note" => "rule /a/, followed_by: /b+/")
    end

    it "leaves trailing context for subsequent tokens in every #{backend} mode" do
      source = <<~RUBY
        require "flexr"
        class TrailingMatchParityLexer < Flexr::Lexer
          backend :#{backend}
          option :experimental
          rule(/a/, followed_by: /b+/, emit: :A)
          rule(/ab/, emit: :AB)
          rule(/b+/, emit: :B)
          rule(/./, emit: :OTHER)
        end
      RUBY

      outcomes = outcomes_for(source, "TrailingMatchParityLexer", %w[abbbb ab a ac])

      expect(outcomes.values.uniq.one?).to be(true), outcomes.inspect
      expect(outcomes[:runtime]).to eq([
        [%w[A a], %w[B bbbb]], [%w[A a], %w[B b]], [%w[OTHER a]], [%w[OTHER a], %w[OTHER c]]
      ])
    end

    it "preserves token limit patterns and rule indices in every #{backend} mode" do
      source = <<~RUBY
        require "flexr"
        class GuardPatternParityLexer < Flexr::Lexer
          backend :#{backend}
          option :experimental
          rule(/a+/i, skip: true)
        end
      RUBY

      outcomes = error_outcomes_for(source, "GuardPatternParityLexer", "AAaa", options: { max_token_size: 2 })

      expect(outcomes.values.uniq.one?).to be(true), outcomes.inspect
      expect(outcomes[:runtime]).to include("code" => "FLEXR-E012", "rule" => 0, "note" => "rule /a+/i at byte 0")
    end
  end

  { "push :missing" => "FLEXR-E003", "public_send(:reject)" => "FLEXR-E013" }.each do |action, code|
    it "preserves #{code} input context and exception class in every mode" do
      source = <<~RUBY
        require "flexr"
        class ActionLocationParityLexer < Flexr::Lexer
          rule(/é|\\n/, skip: true)
          rule(/a/) { #{action} }
        end
      RUBY

      outcomes = error_outcomes_for(source, "ActionLocationParityLexer", "é\néa")

      expect(outcomes.values.uniq.one?).to be(true), outcomes.inspect
      expect(outcomes[:runtime]).to include("class" => "Flexr::CompileError", "code" => code,
                                            "filename" => "input.txt", "byte_pos" => 6, "location" => [6, 6])
    end
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
