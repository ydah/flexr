# frozen_string_literal: true

require "stringio"

RSpec.describe "flexr diff" do
  def compare(left, right, *options, source_encoding: "UTF-8")
    Dir.mktmpdir("flexr-diff-") do |directory|
      old_path = File.join(directory, "left.flexr.rb")
      new_path = File.join(directory, "right.flexr.rb")
      [old_path, new_path].zip([left, right]).each do |path, body|
        File.write(path, "# encoding: #{source_encoding}\nraise 'the specification must not execute'\nclass DiffLexer < Flexr::Lexer\n#{body}\nend\n")
      end
      out = StringIO.new
      err = StringIO.new
      status = Flexr::CLI.run(["diff", old_path, new_path, *options], out: out, err: err)
      [status, out.string, err.string]
    end
  end

  def compare_json(left, right, **)
    status, output, errors = compare(left, right, "--format", "json", **)
    expect(errors).to be_empty
    [status, JSON.parse(output, symbolize_names: true).fetch(:states)]
  end

  it "reports the shortest source and both selected body lengths for each changed state" do
    left = <<~SPEC
      rule(/[0-9]+/, emit: :NUMBER)
      rule(".", emit: :DOT)
      state(:string, inclusive: false) { rule(/[a-z]+/, emit: :TEXT) }
    SPEC
    right = left.sub('rule(".", emit: :DOT)', "rule(/[0-9]+\\./, emit: :FLOAT)\nrule(\".\", emit: :DOT)")
    status, states = compare_json(left, right)
    expect(status).to eq(1)
    initial, string = states
    expect(initial).to include(state: "initial", status: "different", input: "0.", offset: 0)
    expect(initial[:left]).to include(length: 1, effect: hash_including(token: "NUMBER"))
    expect(initial[:right]).to include(length: 2, effect: hash_including(token: "FLOAT"))
    expect(string).to eq(state: "string", status: "equal")
  end

  it "shows the preceding source prefix and offset for lookbehind differences" do
    left = 'rule(/(?<=x)a/, emit: :A)'
    right = 'rule(/(?<=y)a/, emit: :A)'
    status, states = compare_json(left, right)
    expect(status).to eq(1)
    expect(states.first).to include(input: "xa", offset: 1)
    expect(states.first[:left]).to include(length: 1)
    expect(states.first[:right]).to be_nil
  end

  it "recognizes a keyword table as equivalent to a literal rule with the same effect" do
    left = <<~SPEC
      rule("if", emit: :IF)
      rule(/[a-z]+/, emit: :WORD)
    SPEC
    right = <<~SPEC
      rule(/[a-z]+/, emit: :WORD)
      keywords({ "if" => :IF }, among: :WORD)
    SPEC
    expect(compare_json(left, right)).to eq([0, [{ state: "initial", status: "equal" }]])

    status, states = compare_json(left, right.sub(":IF", ":COND"))
    expect(status).to eq(1)
    expect(states.first).to include(input: "if", offset: 0)
    expect(states.first[:right][:effect]).to include(token: "COND")
  end

  it "reports changed static state operations while preserving skip versus no match" do
    preamble = "state(:one, inclusive: false) {}\nstate(:two, inclusive: false) {}\n"
    left = "#{preamble}rule(\"x\") { push :one; skip }"
    right = "#{preamble}rule(\"x\") { push_state :two; skip }"
    status, states = compare_json(left, right)
    expect(status).to eq(1)
    expect(states.first).to include(input: "x", offset: 0)
    expect(states.first[:left][:effect]).to include(action: "skip", state_operations: [%w[push one]])
    expect(states.first[:right][:effect]).to include(action: "skip", state_operations: [%w[push two]])

    status, states = compare_json(left, preamble)
    expect(status).to eq(1)
    expect(states.first[:left][:length]).to eq(1)
    expect(states.first[:right]).to be_nil
  end

  it "returns an inconclusive result for reachable Ruby actions with unknown effects" do
    dynamic = 'rule("x") { emit token_from_input }'
    status, states = compare_json(dynamic, dynamic)
    expect(status).to eq(2)
    expect(states.first).to include(state: "initial", status: "inconclusive", reason: a_kind_of(String))
  end

  it "leaves invalid literal state targets in actions opaque during static reading" do
    source = 'rule("a") { begin_state("\xff") }'
    status, states = compare_json(source, source)
    expect(status).to eq(2)
    expect(states.first).to include(status: "inconclusive", reason: /opaque/)
  end

  it "renders non-UTF-8 binary witnesses as JSON byte arrays" do
    left = <<~'SPEC'
      encoding Encoding::BINARY
      rule(/\xff/n, emit: :BYTE)
    SPEC
    status, states = compare_json(left, left.sub(":BYTE", ":OTHER"))
    expect(status).to eq(1)
    expect(states.first).to include(input: [255], offset: 0)
  end

  it "preserves binary token names in JSON" do
    left = 'rule("a", emit: :"\xff")'
    status, states = compare_json(left, 'rule("a", emit: :OTHER)', source_encoding: "ASCII-8BIT")
    expect(status).to eq(1)
    expect(states.first[:left][:effect][:token]).to eq([255])
  end

  it "never treats equal longest-match languages as a proof for ordered matching" do
    left = <<~SPEC
      backend :firstmatch
      rule(/a|ab/, emit: :A)
    SPEC
    status, states = compare_json(left, left.sub("a|ab", "ab|a"))
    expect(status).to eq(2)
    expect(states.first).to include(status: "inconclusive", reason: /firstmatch/)
  end

  it "reports static parse errors at the right-hand source" do
    status, output, errors = compare('rule("x", emit: :X)', "rule(")
    expect(status).to eq(2)
    expect(output).to be_empty
    expect(errors).to include("right.flexr.rb", "FLEXR-E010")
  end

  it "attributes a trailing-context compile error to the input where it occurs" do
    left = 'rule("x", followed_by: /a*/, emit: :X)'
    status, output, errors = compare(left, 'rule("x", emit: :X)')
    expect(status).to eq(2)
    expect(output).to be_empty
    expect(errors).to include("left.flexr.rb", "FLEXR-E005")
  end

  it "rejects evaluation" do
    status, output, errors = compare('rule("x", emit: :X)', 'rule("x", emit: :Y)', "--eval")
    expect(status).to eq(2)
    expect(output).to be_empty
    expect(errors).to include("requires a statically readable spec")
  end
end
