# frozen_string_literal: true

require "stringio"

RSpec.describe "DFA backup analysis" do
  def dfa_for(*patterns)
    lexer = Class.new(Flexr::Lexer) do
      patterns.each { |pattern| rule(pattern, emit: :TOKEN) }
    end
    lexer.compile!.machines.fetch(:initial).dfa
  end

  def backup_for(*patterns)
    Flexr::Automaton::Analysis.backup(dfa_for(*patterns))
  end

  it "reports zero when a successful transition after acceptance always accepts again" do
    expect(backup_for(/a+/, /b/)).to have_attributes(maximum_bytes: 0, example: nil, cycle: nil)
  end

  it "finds the longest finite path after acceptance across branches" do
    expect(backup_for(/a/, /abc/, /adefg/)).to have_attributes(maximum_bytes: 3, example: nil, cycle: nil)
  end

  it "separates the shortest unbounded example from its repeatable cycle" do
    expect(backup_for(/a/, /a*b/)).to have_attributes(maximum_bytes: nil, example: "aa".b, cycle: "a".b)
  end

  it "finds a short example even when a different nonaccepting cycle is found first" do
    expect(backup_for(/a/, /ab{2}b*c/, /z/, /zy*x/)).to have_attributes(
      maximum_bytes: nil, example: "zy".b, cycle: "y".b
    )
  end

  it "selects a deterministic example among equally short prefixes" do
    expect(backup_for(/z/, /zy*x/, /a/, /ab*c/)).to have_attributes(
      maximum_bytes: nil, example: "ab".b, cycle: "b".b
    )
  end

  it "ignores a loop that can only be reached before any acceptance" do
    expect(backup_for(/a*b/)).to have_attributes(maximum_bytes: 0, example: nil, cycle: nil)
  end

  it "resets the backup length whenever a cycle visits an accepting state" do
    expect(backup_for(/a(?:bc)*/)).to have_attributes(maximum_bytes: 1, example: nil, cycle: nil)
  end

  it "counts UTF-8 transitions in bytes" do
    expect(backup_for(/x/, /xéz/)).to have_attributes(maximum_bytes: 2, example: nil, cycle: nil)
  end

  it "selects nonaccepting cycle states and excludes bounded branches from the failure table" do
    dfa = dfa_for(/a/, /a*b/, /az{3}x/)
    states, = Flexr::Automaton::Analysis.backup_memo_states(dfa)
    after_a = dfa.transition(dfa.start, "a".ord)
    after_aa = dfa.transition(after_a, "a".ord)
    after_az = dfa.transition(after_a, "z".ord)

    expect(states[after_a]).to be_falsey
    expect(states[after_aa]).to be true
    expect(states[after_az]).to be_falsey
  end

  it "adds cycles before the first acceptance when scanning can recover from an unmatched byte" do
    dfa = dfa_for(/a*b/)
    states, recovery_states = Flexr::Automaton::Analysis.backup_memo_states(dfa)

    expect(states).to be_nil
    expect(recovery_states[dfa.transition(dfa.start, "a".ord)]).to be true
  end

  context "when inspecting a lexer specification" do
    around do |example|
      Dir.mktmpdir("flexr-backup-") do |directory|
        @path = File.join(directory, "lexer.flexr.rb")
        File.binwrite(@path, <<~RUBY)
          class BackupLexer < Flexr::Lexer
            rule(/a/, emit: :A)
            rule(/a*b/, emit: :AB)
            state :bounded do
              rule(/x/, emit: :X)
              rule(/xy{3}z/, emit: :LONG)
            end
          end
        RUBY
        example.run
      end
    end

    def inspect_spec(command, *options)
      output = StringIO.new
      errors = StringIO.new
      status = Flexr::CLI.run([command, @path, *options], out: output, err: errors)
      expect(status).to eq(0), errors.string
      expect(errors.string).to be_empty
      output.string
    end

    it "explains the maximum DFA backup separately in each lexical state" do
      expect(inspect_spec("explain")).to include(
        "state :initial: maximum DFA backup: unbounded",
        "state :bounded: maximum DFA backup: 3 bytes"
      )
    end

    it "includes the DFA backup bounds in DOT and structural trace" do
      %w[dot trace].each do |command|
        expect(inspect_spec(command)).to include("state :bounded: maximum DFA backup: 3 bytes")
      end
    end

    it "omits DFA backup analysis for first-match scanning" do
      expect(inspect_spec("explain", "--backend", "firstmatch")).not_to include("DFA backup")
      expect(inspect_spec("check", "--backend", "firstmatch", "--warn", "all")).not_to include("FLEXR-W023")
    end

    it "warns about unbounded DFA backup with the prefix and repeatable suffix" do
      output = inspect_spec("check", "--warn", "all", "--format", "json")
      warnings = JSON.parse(output).select { |item| item.fetch("code") == "FLEXR-W023" }

      expect(warnings).to contain_exactly(include(
        "severity" => "warning",
        "message" => /state :initial/,
        "note" => include('"aa"', '"a"')
      ))
    end
  end
end
