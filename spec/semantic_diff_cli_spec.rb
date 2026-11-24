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

  it "compares shortest and longest states using the same trailing eligibility" do
    longest = <<~SPEC
      state(:raw) do
        rule("a", followed_by: "b", emit: :PREFIX)
        rule("ab", priority: 1, emit: :WORD)
      end
    SPEC
    shortest = longest.sub("state(:raw)", "state(:raw, match: :shortest)")
    status, states = compare_json(longest, shortest)

    expect(status).to eq(1)
    expect(states.first).to eq(state: "initial", status: "equal")
    expect(states.last).to include(state: "raw", status: "different", input: "ab", offset: 0)
    expect(states.last[:left]).to include(length: 2, effect: hash_including(token: "WORD"))
    expect(states.last[:right]).to include(length: 1, effect: hash_including(token: "PREFIX"))
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

  it "finds a changed ordered endpoint even when the accepted language is equal" do
    left = <<~SPEC
      backend :firstmatch
      rule(/a|ab/, emit: :A)
    SPEC
    status, states = compare_json(left, left.sub("a|ab", "ab|a"))
    expect(status).to eq(1)
    expect(states.first).to include(status: "different", input: "ab", offset: 0)
    expect([states.first[:left][:length], states.first[:right][:length]]).to eq([1, 2])
  end

  it "proves the longest pattern of a firstmatch rule agrees with a greedy alternative" do
    left = <<~SPEC
      backend :firstmatch
      rule([/a/, /ab/], emit: :A)
    SPEC
    right = left.sub("[/a/, /ab/]", "/ab|a/")
    expect(compare_json(left, right)).to eq([0, [{ state: "initial", status: "equal" }]])
  end

  it "distinguishes the first matching rule from the longest matching rule" do
    rules = <<~SPEC
      rule(/a/, emit: :SHORT)
      rule(/ab/, emit: :LONG)
    SPEC
    status, states = compare_json("backend :firstmatch\n#{rules}", rules)
    expect(status).to eq(1)
    expect(states.first).to include(status: "different", input: "ab", offset: 0)
    expect(states.first[:left]).to include(length: 1, effect: hash_including(token: "SHORT"))
    expect(states.first[:right]).to include(length: 2, effect: hash_including(token: "LONG"))
  end

  it "preserves declaration order across local and inherited firstmatch rules" do
    state = "state(:inside, inclusive: true) { rule(/ab/, emit: :LONG) }"
    initial = "rule(/a/, emit: :SHORT)"
    left = "backend :firstmatch\n#{state}\n#{initial}"
    right = "backend :firstmatch\n#{initial}\n#{state}"

    status, states = compare_json(left, right)
    expect(status).to eq(1)
    expect(states.first).to eq(state: "initial", status: "equal")
    expect(states.last).to include(state: "inside", status: "different", input: "ab", offset: 0)
    expect([states.last[:left][:length], states.last[:right][:length]]).to eq([2, 1])
  end

  it "reports ordered differences on binary input as byte arrays" do
    left = <<~'SPEC'
      encoding Encoding::BINARY
      backend :firstmatch
      rule(/\xff|\xffa/n, emit: :BYTE)
    SPEC
    right = left.sub('\xff|\xffa', '\xffa|\xff')
    status, states = compare_json(left, right)
    expect(status).to eq(1)
    expect(states.first).to include(input: [255, 97], offset: 0)
    expect([states.first[:left][:length], states.first[:right][:length]]).to eq([1, 2])
  end

  it "compares firstmatch accepts with their right and left context" do
    left = <<~SPEC
      backend :firstmatch
      rule(/(?<=x)a(?!bc)/, emit: :A)
    SPEC
    status, states = compare_json(left, left.sub("<=x", "<=y"))
    expect(status).to eq(1)
    expect(states.first).to include(input: "xa", offset: 1)
    expect(states.first[:left]).to include(length: 1)
    expect(states.first[:right]).to be_nil

    status, states = compare_json(left, left.sub("(?!bc)", ""))
    expect(status).to eq(1)
    expect(states.first).to include(input: "xabc", offset: 1)
    expect(states.first[:left]).to be_nil
    expect(states.first[:right]).to include(length: 1)
  end

  it "keeps CRLF together when comparing an ordered grapheme match" do
    left = <<~'SPEC'
      backend :firstmatch
      rule(/\X/, emit: :CHAR)
    SPEC
    status, states = compare_json(left, left.sub('\X', '(?m:.)'))
    expect(status).to eq(1)
    expect(states.first).to include(input: "\r\n", offset: 0)
    expect([states.first[:left][:length], states.first[:right][:length]]).to eq([2, 1])
  end

  it "tests trailing context after choosing the longest pattern of a firstmatch rule" do
    left = <<~SPEC
      backend :firstmatch
      rule([/a/, /ab/], followed_by: /b/, emit: :FIRST)
      rule(/ab/, emit: :SECOND)
    SPEC
    status, states = compare_json(left, left.sub("[/a/, /ab/]", "/a/"))
    expect(status).to eq(1)
    expect(states.first).to include(input: "ab", offset: 0)
    expect(states.first[:left]).to include(length: 2, effect: hash_including(token: "SECOND"))
    expect(states.first[:right]).to include(length: 1, effect: hash_including(token: "FIRST"))
  end

  it "checks the terminal anchor of the selected vendored pattern before trying the next rule" do
    left = <<~SPEC
      backend :firstmatch
      rule([/a/, /a[[:digit:]]$/], emit: :A)
    SPEC
    right = <<~SPEC
      backend :firstmatch
      rule(/a[[:digit:]]$/, emit: :A)
      rule(/a/, emit: :A)
    SPEC
    status, states = compare_json(left, right)
    expect(status).to eq(1)
    expect(states.first).to include(input: "a0 ", offset: 0, left: nil)
    expect(states.first[:right]).to include(length: 1, effect: hash_including(token: "A"))
  end

  it "keeps firstmatch uncertainty local to the states with native case folding" do
    source = <<~SPEC
      backend :firstmatch
      rule(/a+/, emit: :A)
      state(:native, inclusive: false) { rule(/ss/i, emit: :NATIVE) }
    SPEC
    status, states = compare_json(source, source)
    expect(status).to eq(2)
    expect(states.first).to eq(state: "initial", status: "equal")
    expect(states.last).to include(state: "native", status: "inconclusive", reason: a_kind_of(String))
  end

  it "leaves bounded nullable Ruby repetitions inconclusive" do
    left = <<~SPEC
      backend :firstmatch
      rule(/(?:a?|b){1,3}a/, emit: :A)
    SPEC
    right = left.sub("(?:a?|b){1,3}", "(?:a?|b)(?:a?|b)?(?:a?|b)?")
    status, states = compare_json(left, right)
    expect(status).to eq(2)
    expect(states.first).to include(status: "inconclusive", reason: /firstmatch/)
  end

  it "leaves a contextual replay with an incompatible input encoding inconclusive" do
    source = <<~SPEC
      encoding Encoding::BINARY
      backend :firstmatch
      rule(/é(?=a)/, emit: :A)
    SPEC
    status, states = compare_json(source, "encoding Encoding::BINARY")
    expect(status).to eq(2)
    expect(states.first).to include(status: "inconclusive", reason: /UTF-8.*ASCII-8BIT/)
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
