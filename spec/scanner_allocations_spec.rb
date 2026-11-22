# frozen_string_literal: true

RSpec.describe "scanner allocations" do
  it "reads packed fallback transitions without allocating per lookup" do
    skip "allocation counts require CRuby" unless RUBY_ENGINE == "ruby"

    rows = [[nil, 0, 1, 0, 1], [nil, 0, 1, 0, 0], [nil, 0, 1, 1, 0]]
    packed = Flexr::Codegen::TablePacker.pack(rows, compression: :full)
    dfa = Flexr::Automaton::DFA.new(accepts: [[], [], []], ec: Array.new(256) { |byte| byte % 5 },
                                   class_count: 5, start: 0, rule_ids: [], packed: packed, state_count: 3)
    expect(packed.fetch(:fallback).fetch(2)).to eq(1)
    rows.each_with_index do |row, state|
      row.each_with_index { |target, byte| expect(dfa.transition(state, byte)).to eq(target) }
    end
    128.times { dfa.transition(2, 2) }

    before = GC.stat(:total_allocated_objects)
    10_000.times { dfa.transition(2, 2) }
    allocated = GC.stat(:total_allocated_objects) - before

    expect(allocated).to be < 50
    expect(dfa.transitions.materialized_count).to eq(0)
  end

  it "emits array tokens without allocating a loop block for every token" do
    skip "allocation counts require CRuby" unless RUBY_ENGINE == "ruby"

    lexer = Class.new(Flexr::Lexer) { rule("a", emit: :A) }
    input = ("a" * 10_000).freeze
    2.times { lexer.new(input).tokens }

    before = GC.stat(:total_allocated_objects)
    tokens = lexer.new(input).tokens
    allocated = GC.stat(:total_allocated_objects) - before

    expect(tokens).to eq([[:A, "a"]] * input.bytesize)
    expect(allocated).to be < tokens.length * 2.5
  end

  it "returns the result of an exhausted action enumerator" do
    values = Enumerator.new { [:END, "done"] }
    lexer = Class.new(Flexr::Lexer) do
      rule("a") { emit :A, values.next }
    end

    expect(lexer.new("a").next_token).to eq([:END, "done"])
  end
end
