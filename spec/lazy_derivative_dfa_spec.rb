# frozen_string_literal: true

require "flexr/automaton/derivative_compiler"

RSpec.describe "on-demand derivative construction" do
  def pattern(regexp, index)
    ast = Flexr::Regexp::Parser.new(regexp.source).parse
    body = Flexr::Regexp::Normalizer.new(ast, encoding: Encoding::UTF_8, options: regexp.options).normalize
    [body, Flexr::Automaton::Acceptance.new(rule_index: index, pattern_index: 0)]
  end

  it "creates states for the transitions an input takes" do
    patterns = [pattern(/abc/, 0), pattern(/z{20}/, 1)]
    dfa = Flexr::Automaton::DerivativeCompiler.new.compile(patterns, lazy: true) { |count| expect(count).to be < 30 }
    expect(dfa.states).to eq(1)

    state = "abc".each_byte.reduce(dfa.start) { |from, byte| dfa.transition(from, byte) }
    expect(dfa.accepts.fetch(state).map(&:rule_index)).to eq([0])
    expect(dfa.states).to eq(4)

    expect(dfa.transition(dfa.start, "x".ord)).to be_nil
    expect(dfa.transition(dfa.start, "x".ord)).to be_nil
    expect("abc".each_byte.reduce(dfa.start) { |from, byte| dfa.transition(from, byte) }).to eq(state)
    expect(dfa.states).to eq(4)

    dfa.transition(dfa.start, "z".ord)
    expect(dfa.states).to eq(5)
  end

  it "checks the state limit before publishing a new transition" do
    dfa = Flexr::Automaton::DerivativeCompiler.new.compile([pattern(/ab/, 0)], lazy: true) do |count, _|
      raise Flexr::CompileError, "state limit" if count >= 2
    end
    prefix = dfa.transition(dfa.start, "a".ord)

    2.times do
      expect { dfa.transition(prefix, "b".ord) }.to raise_error(Flexr::CompileError, "state limit")
      expect(dfa.states).to eq(2)
    end
  end

  it "scans without visiting unused branches and preserves explicit compilation" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/abc/, emit: :WORD)
      rule(/z{20}/, emit: :LONG)
      rule(/abc/, emit: :SHADOWED)
    end
    lexer = lexer_class.new("abc")
    runtime = lexer_class.__flexr_runtime_compiled.machines.fetch(:initial).dfa
    expect(runtime.states).to eq(1)
    expect(lexer.tokens).to eq([[:WORD, "abc"]])
    expect(runtime.states).to eq(4)

    compiled = lexer_class.compile!
    expect(compiled.machines.fetch(:initial).dfa.states).to be > runtime.states
    expect(compiled.diagnostics.map(&:code)).to include("FLEXR-W001")
    expect(lexer_class.new("z" * 20).tokens).to eq([[:LONG, "z" * 20]])
  end
end
