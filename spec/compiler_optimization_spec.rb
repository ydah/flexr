# frozen_string_literal: true

RSpec.describe "compiler and generated runtime optimizations" do
  it "keeps the lightweight Unicode runtime version aligned with generated data" do
    expect(Flexr::Unicode::VERSION).to eq(Flexr::Unicode::Data::VERSION)
  end

  def dfa_for(rows, accepting: [])
    accepts = rows.each_index.map do |state|
      if accepting.include?(state)
        [Flexr::Automaton::Acceptance.new(
          rule_index: 0, pattern_index: 0, bol_only: false, end_anchor: false
        )]
      else
        []
      end
    end
    Flexr::Automaton::DFA.new(
      transitions: rows, accepts: accepts, ec: Array.new(128, 0) + Array.new(128, 1),
      class_count: rows.first.length, start: 0, rule_ids: [0]
    )
  end

  it "minimizes equivalent states with Hopcroft partition refinement" do
    original = dfa_for([[1, 2], [1, 3], [1, 3], [3, 3]], accepting: [3])
    minimized = Flexr::Automaton::Minimizer.minimize(original)

    expect(minimized.states).to eq(3)
    inputs = (0..5).flat_map { |length| [0, 127].repeated_permutation(length).to_a }
    inputs.each do |bytes|
      input = bytes.pack("C*")
      expect(minimized.accept?(input)).to eq(original.accept?(input))
    end
  end

  it "folds reachable dead states into the implicit missing transition" do
    original = dfa_for([[1, 2], [nil, nil], [2, 2]], accepting: [2])
    minimized = Flexr::Automaton::Minimizer.minimize(original)

    expect(minimized.states).to eq(2)
    expect(minimized.transitions.fetch(0)).to eq([nil, 1])
    expect(minimized.accept?("\x00".b)).to be(false)
    expect(minimized.accept?("\x80".b)).to be(true)
  end

  it "keeps one start state when the entire language is dead" do
    original = dfa_for([[1, nil], [nil, nil]])
    minimized = Flexr::Automaton::Minimizer.minimize(original)

    expect(minimized.states).to eq(1)
    expect(minimized.transitions).to eq([[nil, nil]])
  end

  it "selects auto backends from representation and lookup costs" do
    dense_rows = Array.new(100) do |state|
      Array.new(16) { |class_id| (state + class_id + 1) % 100 }
    end
    sparse_rows = Array.new(100) do |state|
      Array.new(16).tap { |row| row[state % 16] = (state + 1) % 100 }
    end
    dense = dfa_for(dense_rows)
    sparse = dfa_for(sparse_rows)
    compiled = lambda do |dfa|
      Flexr::Automaton::CompiledSpec.new(
        machines: { initial: Flexr::Automaton::Machine.new(dfa: dfa, state_name: :initial) },
        rules: [], states: [:initial], stats: {}, diagnostics: []
      )
    end

    expect(Flexr::Automaton::BackendCostModel.choose(compiled.call(dense))).to eq(:direct)
    expect(Flexr::Automaton::BackendCostModel.choose(compiled.call(sparse))).to eq(:table)
  end

  it "selects auto backends using total cost across lexical states" do
    dense = dfa_for(Array.new(4) { |state| Array.new(16) { |class_id| (state + class_id + 1) % 4 } })
    sparse = dfa_for(Array.new(100) do |state|
      Array.new(16).tap { |row| row[state % 16] = (state + 1) % 100 }
    end)
    compiled = Flexr::Automaton::CompiledSpec.new(
      machines: {
        initial: Flexr::Automaton::Machine.new(dfa: dense, state_name: :initial),
        sparse: Flexr::Automaton::Machine.new(dfa: sparse, state_name: :sparse)
      },
      rules: [], states: %i[initial sparse], stats: {}, diagnostics: []
    )

    expect(Flexr::Automaton::BackendCostModel.metrics_for(dense).direct_score).to be <
      Flexr::Automaton::BackendCostModel.metrics_for(dense).table_score
    expect(Flexr::Automaton::BackendCostModel.choose(compiled)).to eq(:table)
  end

  it "chooses the generated fast path independently for each lexical state" do
    Dir.mktmpdir do |directory|
      source = File.join(directory, "states.flexr.rb")
      output = File.join(directory, "states.generated.rb")
      File.write(source, <<~RUBY)
        require "flexr"

        class StateSpecificScannerLexer < Flexr::Lexer
          rule(/a+/) { emit :WORD }
          state :context do
            rule(/b/, followed_by: /c+/) { emit :B }
          end
        end
      RUBY
      Flexr::Generator.new(source, output: output).generate
      load output
      lexer = StateSpecificScannerLexer.new("a")
      machines = StateSpecificScannerLexer.compile!.machines

      expect(lexer.send(:__flexr_generated_fast_path?, machines.fetch(:initial).dfa)).to be(true)
      expect(lexer.send(:__flexr_generated_fast_path?, machines.fetch(:context).dfa)).to be(false)
    ensure
      Object.send(:remove_const, :StateSpecificScannerLexer) if
        Object.const_defined?(:StateSpecificScannerLexer, false)
    end
  end
end
