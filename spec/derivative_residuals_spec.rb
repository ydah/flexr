# frozen_string_literal: true

require "stringio"

RSpec.describe "DFA residual diagnostics" do
  let(:source) do
    <<~SPEC
      class ResidualLexer < Flexr::Lexer
        rule(/a(?<middle>b*)c/) { emit :WORD, captures[:middle] }
        rule(/a[x-z]+/, emit: :OTHER)
        state :nested do
          rule(/pq/, emit: :PAIR)
        end
      end
    SPEC
  end

  def run_diagnostic(command, *args)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.write(path, source)
      output = StringIO.new
      errors = StringIO.new
      status = Flexr::CLI.run([command, path, *args], out: output, err: errors)
      [status, output.string, errors.string]
    end
  end

  it "shows the requested rule's remaining expression for minimized states in explain" do
    status, output, errors = run_diagnostic("explain", "--rule", "0", "--residuals")

    expect(status).to eq(0), errors
    expect(output).to match(/state initial DFA \d+: rule 0 pattern 0: b\*c/)
    expect(output).not_to include("rule 1")
    expect(run_diagnostic("explain")[1]).not_to match(/state \S+ DFA \d+:/)
  end

  it "labels the same states as the transition table and keeps separate lexical states" do
    status, output, errors = run_diagnostic("trace", "--residuals")

    expect(status).to eq(0), errors
    expect(output).to match(/\d+: accepts=.*transitions=.*residuals=.*rule 0 pattern 0: b\*c/)
    expect(output).to include("state nested", "rule 2 pattern 0: q")
  end

  it "reports residuals after each matched byte in both runtime and generated input traces" do
    traces = [[], ["--generated"]].map do |mode|
      status, output, errors = run_diagnostic("trace", "--input", "abbc", "--format", "json", "--residuals", *mode)
      expect(status).to eq(0), errors
      JSON.parse(output)
    end
    expect(traces.first).to eq(traces.last)
    step = traces.first.fetch("steps").fetch(0)
    expect(step).to include("token" => '[:WORD, "bb"]')
    path = step.fetch("dfa_path")
    expect(path.map { |entry| entry.fetch("byte_offset") }).to eq([0, 1, 2, 3, 4])
    expect(path.fetch(1).fetch("residuals")).to include("rule" => 0, "pattern" => 0, "expression" => "b*c")
    expect(path.last.fetch("residuals")).to eq([{ "rule" => 0, "pattern" => 0, "expression" => "ε" }])

    status, human, errors = run_diagnostic("trace", "--input", "abbc", "--residuals")
    expect(status).to eq(0), errors
    expect(human).to match(/@1 DFA \d+: rule 0 pattern 0: b\*c/)
  end

  it "uses one description when minimization merges equivalent residuals" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a(?:b|c)|z[bc]/, emit: :WORD)
    end
    trace = Flexr::Trace.new(lexer_class.new("abzc"), residuals: true)
    expect(trace.run).to eq([[:WORD, "ab"], [:WORD, "zc"]])
    first, second = trace.steps.map { |step| step.fetch(:dfa_path).fetch(1) }
    expect(first.values_at(:state, :residuals)).to eq(second.values_at(:state, :residuals))
    expect(first.fetch(:residuals).first.fetch(:expression)).to match(/b.*c/)
  end

  it "describes the bytes that matched before the action edits the input buffer" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule("ab") do
        buffer.source.setbyte(1, "x".ord)
        emit(:WORD, "ab")
      end
      rule("c", emit: :TAIL)
    end
    trace = Flexr::Trace.new(lexer_class.new(StringIO.new("abc")), residuals: true)
    expect(trace.run).to eq([[:WORD, "ab"], [:TAIL, "c"]])
    step = trace.steps.first
    expect(step.fetch(:bytes)).to eq([97, 98])
    path = step.fetch(:dfa_path)
    expect(path.map { |entry| entry.fetch(:byte_offset) }).to eq([0, 1, 2])
    expect(path.last.fetch(:residuals)).to eq([{ rule: 0, pattern: 0, expression: "ε" }])
  end

  it "reports byte-level residuals for binary input without invalid display encoding" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "bytes.flexr.rb")
      input = File.join(directory, "bytes.bin")
      File.write(path, 'class ByteLexer < Flexr::Lexer; encoding Encoding::BINARY; rule(/a\xFF/n, emit: :BYTE); end')
      File.binwrite(input, "a\xff".b)
      output = StringIO.new
      errors = StringIO.new

      status = Flexr::CLI.run(["trace", path, "--input-file", input, "--format", "json", "--residuals"], out: output, err: errors)
      expect(status).to eq(0), errors.string
      step = JSON.parse(output.string).fetch("steps").fetch(0)
      expect(step.fetch("bytes")).to eq([97, 255])
      expect(step.fetch("dfa_path").fetch(1).fetch("residuals").first.fetch("expression")).to eq("\\xFF")
    end
  end

  it "rejects residual output for first-match execution" do
    status, output, errors = run_diagnostic("explain", "--backend", "firstmatch", "--residuals")
    expect(status).to eq(2)
    expect(output).to be_empty
    expect(errors).to include("requires a longest-match backend")
  end

  it "rejects residual output for commands that have no DFA view" do
    status, _, errors = run_diagnostic("check", "--residuals")

    expect(status).to eq(2)
    expect(errors).to include("only valid for explain or trace")
  end
end
