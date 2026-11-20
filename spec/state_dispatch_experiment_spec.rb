# frozen_string_literal: true

require "stringio"

RSpec.describe "state dispatch experiment" do
  it "preserves every transition and token while replacing generated table dispatch" do
    require_relative "../benchmark/state_dispatch"
    path = File.expand_path("../examples/json/lexer.flexr.rb", __dir__)
    table, direct, switched = Flexr::Benchmarking::StateDispatch.lexers(path)
    source = '{"answer":42,"text":"hello"}'
    expect(switched.new(source).tokens).to eq(table.new(source).tokens)
    expect(switched.new(source).tokens).to eq(direct.new(source).tokens)
    expect(switched.new(StringIO.new(source), chunk_size: 1).tokens).to eq(table.new(source).tokens)
    dfa = table.__flexr_compiled.machines.fetch(:initial).dfa
    instance = switched.new("")
    dfa.states.times do |state|
      256.times do |byte|
        expect(instance.__flexr_state_transition(state, dfa.ec[byte])).to eq(dfa.transition(state, byte))
      end
    end
  end
end
