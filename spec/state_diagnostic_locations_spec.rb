# frozen_string_literal: true

require "stringio"

RSpec.describe "state diagnostic locations" do
  around do |example|
    Dir.mktmpdir("flexr-state-locations") do |directory|
      @path = File.join(directory, "lexer.flexr.rb")
      @output_path = File.join(directory, "lexer.rb")
      example.run
    end
  ensure
    Object.send(:remove_const, :StateLocationFixture) if Object.const_defined?(:StateLocationFixture, false)
  end

  def write_spec(body)
    @class_source = "class StateLocationFixture < Flexr::Lexer\n#{body}\nend"
    @source = "# UTF-8: é\n#{@class_source}\n"
    File.binwrite(@path, @source)
  end

  def span(fragment)
    offset = @source.b.index(fragment.b)
    [offset, offset + fragment.bytesize]
  end

  def check(*args)
    output = StringIO.new
    errors = StringIO.new
    status = Flexr::CLI.run(["check", @path, "--format", "json", *args], out: output, err: errors)
    [status, JSON.parse(output.string + errors.string)]
  end

  it "locates empty states at their first declaration, including nested and shared declarations" do
    statement = "state(:empty, :other) {}"
    write_spec("  rule(/a/, skip: true)\n  state :outer do\n    rule(/b/, skip: true)\n    #{statement}\n  end\n  state(:empty) {}")

    status, diagnostics = check
    warnings = diagnostics.select { |item| item.fetch("code") == "FLEXR-W002" }

    expect(status).to eq(0)
    expect(warnings.map { |item| item.fetch("message") })
      .to eq(["state :empty has no rules", "state :other has no rules"])
    expect(warnings.map { |item| item["location"] }).to eq([span(statement), span(statement)])

    generator = Flexr::Generator.new(@path, output: @output_path)
    generator.generate
    generated_warnings = generator.diagnostics.select { |item| item.code == "FLEXR-W002" }
    expect(generated_warnings.map(&:location)).to eq([span(statement), span(statement)])

    load @output_path
    expect(StateLocationFixture.__flexr_compiled.diagnostics.select { |item| item.code == "FLEXR-W002" }.map(&:to_h))
      .to eq(generated_warnings.map(&:to_h))
  end

  it "renders the empty state's declaration through the CLI" do
    write_spec("  state(:empty) {}\n  rule(/a/, skip: true)")
    output = StringIO.new
    errors = StringIO.new

    status = Flexr::CLI.run(["check", @path, "--color", "never"], out: output, err: errors)

    expect(status).to eq(0)
    expect(errors.string).to be_empty
    expect(output.string).to include("warning[FLEXR-W002]", "  --> #{@path}:3:3\n",
                                     "3 |   state(:empty) {}\n", "  |   ^^^^^^^^^^^^^^^^\n")
  end

  it "preserves state locations when generation treats warnings as errors" do
    statement = "state(:empty) {}"
    write_spec("  #{statement}\n  rule(/a/, skip: true)")

    expect { Flexr::Generator.new(@path, options: { warn_as_error: true }).generate }
      .to raise_error(Flexr::CompileError) do |error|
        expect(error.diagnostic.code).to eq("FLEXR-W002")
        expect(error.diagnostic.location).to eq(span(statement))
      end
  end

  %i[initial word].each do |state|
    it "locates the DFA limit error for the #{state} state in check and generation" do
      statement = "state(:word) { rule(/ab/, skip: true) }"
      write_spec(state == :initial ? "  rule(/ab/, skip: true)" : "  #{statement}")
      expected = span(state == :initial ? @class_source : statement)

      status, diagnostics = check("--max-dfa-states", "1")

      expect(status).to eq(1)
      expect(diagnostics.first).to include("code" => "FLEXR-E006", "location" => expected)
      expect(diagnostics.first.fetch("message")).to eq("DFA state limit exceeded while compiling rule /ab/")
      expect { Flexr::Generator.new(@path, options: { max_dfa_states: 1 }).generate }
        .to raise_error(Flexr::CompileError) do |error|
          expect(error.diagnostic.code).to eq("FLEXR-E006")
          expect(error.diagnostic.location).to eq(expected)
          expect(error.diagnostic.message).to eq("DFA state limit exceeded while compiling rule /ab/")
        end
    end
  end

  it "preserves rule locations when machine compilation fails within a state" do
    statement = "rule(/a^b/, skip: true)"
    write_spec("  option :allow_empty_match\n  state(:word) { #{statement} }")

    status, diagnostics = check

    expect(status).to eq(1)
    expect(diagnostics.first).to include("code" => "FLEXR-E009", "location" => span(statement))
  end

  %i[initial word].each do |largest_state|
    it "locates the largest table at #{largest_state} and the total construction time at the lexer class" do
      class_location = [10, 100]
      state_location = [40, 80]
      states = {
        initial: Flexr::IR::State.new(name: :initial, inclusive: true, id: 0, location: class_location),
        word: Flexr::IR::State.new(name: :word, inclusive: false, id: 1, location: state_location)
      }
      spec = Flexr::IR::Spec.new(states: states, rules: [], options: {}, declared_tokens: [])
      compiled = Flexr::Automaton::CompiledSpec.new(
        machines: {}, stats: { initial: { states: 1, classes: 1 }, word: { states: 1, classes: 1 } }
      )
      compiled.stats[largest_state] = { states: 2_001, classes: 501 }

      diagnostics = Flexr::Automaton::Compiler.new(spec).send(:diagnostics_for, compiled, 0.501)

      expect(diagnostics.find { |item| item.code == "FLEXR-W011" }.location)
        .to eq(largest_state == :initial ? class_location : state_location)
      expect(diagnostics.find { |item| item.code == "FLEXR-W016" }.location).to eq(class_location)
    end
  end

  it "leaves state locations absent for the runtime DSL without source metadata" do
    lexer = Class.new(Flexr::Lexer) do
      state(:empty) { nil }
      rule(/ab/, skip: true)
    end

    expect(lexer.compile!.diagnostics.find { |item| item.code == "FLEXR-W002" }.location).to be_nil

    limited = Class.new(Flexr::Lexer) { rule(/ab/, skip: true) }
    limited.__flexr_config.options[:max_dfa_states] = 1
    expect { limited.compile! }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E006")
      expect(error.diagnostic.location).to be_nil
    end
  end
end
