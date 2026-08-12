# frozen_string_literal: true

require "stringio"

RSpec.describe "regexp engine contracts" do
  it "distinguishes the empty language from an empty match in binary mode" do
    lexer_class = Class.new(Flexr::Lexer) do
      encoding Encoding::BINARY
      rule("Ā") { emit :IMPOSSIBLE }
      rule(/./n) { emit :BYTE }
    end

    normalized = Flexr::Regexp::Normalizer.new(
      Flexr::Regexp::Parser.new("Ā", encoding: Encoding::BINARY).parse,
      encoding: Encoding::BINARY
    ).normalize
    expect(normalized).to be_a(Flexr::Regexp::AST::Fail)
    expect(lexer_class.new("A".b).tokens).to eq([[:BYTE, "A".b]])
  end

  it "keeps repetition symbolic through parsing and supports open bounds" do
    plus = Flexr::Regexp::Parser.new("é+").parse
    bounded = Flexr::Regexp::Parser.new("a{2,4}").parse
    open = Flexr::Regexp::Parser.new("a{2,}").parse

    expect([plus.minimum, plus.maximum, plus.loc, plus.child.loc]).to eq([1, nil, 0...3, 0...2])
    expect(Flexr::Regexp::Parser.new("(é)").parse.loc).to eq(1...3)
    expect([bounded.minimum, bounded.maximum]).to eq([2, 4])
    expect([open.minimum, open.maximum]).to eq([2, nil])
    expect(Flexr.compile_pattern(/a{2,}/).accept?("aa")).to be(true)
    expect(Flexr.compile_pattern(/a{2,}/).accept?("a")).to be(false)
  end

  it "supports Ruby-compatible trailing hyphens, hex escapes, and class intersections" do
    trailing_hyphen = Flexr.compile_pattern(/[a-]/)
    hex = Flexr.compile_pattern(/\h+/)
    consonants = Flexr.compile_pattern(/[a-z&&[^aeiou]]+/)
    backspace = Flexr.compile_pattern(/[\b]/)

    expect([trailing_hyphen.accept?("a"), trailing_hyphen.accept?("-")]).to eq([true, true])
    expect([hex.accept?("09Af"), hex.accept?("gh")]).to eq([true, false])
    expect([consonants.accept?("flxr"), consonants.accept?("ae")]).to eq([true, false])
    expect(backspace.accept?("\b")).to be(true)
  end

  it "rejects unknown and unsupported escapes instead of treating them as literals" do
    %w[\\q \\g<name> \\R \\X \\cA \\M-a].each do |source|
      expect { Flexr::Regexp::Parser.new(source).parse }
        .to raise_error(Flexr::UnsupportedRegexpError) do |error|
          expect(error.diagnostic.code).to eq("FLEXR-E014")
        end
    end
    expect { Flexr::Regexp::Parser.new("\\.").parse }.not_to raise_error
  end

  it "compiles Unicode properties into the DFA with longest-match semantics" do
    dfa = Flexr.compile_pattern(/\p{L}|\p{L}{2}/)
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/\p{L}|\p{L}{2}/) { emit :WORD }
    end

    expect(dfa).to be_a(Flexr::Automaton::DFA)
    expect(dfa.states).to be < 1_000
    expect(lexer_class.new("ab").tokens).to eq([[:WORD, "ab"]])
    expect(lexer_class.new(StringIO.new("ab"), chunk_size: 1).tokens).to eq([[:WORD, "ab"]])
  end

  it "uses the generated scanner fast path for Unicode properties" do
    Dir.mktmpdir do |directory|
      source = File.join(directory, "property.flexr.rb")
      output = File.join(directory, "property.generated.rb")
      File.write(source, <<~RUBY)
        require "flexr"

        class GeneratedPropertyDfaLexer < Flexr::Lexer
          rule(/\\p{L}|\\p{L}{2}/) { emit :WORD }
        end
      RUBY
      generated = Flexr::Generator.new(source, output: output).generate
      load output

      expect(generated).not_to include("pattern.source.match?")
      expect(GeneratedPropertyDfaLexer.new("ab").tokens).to eq([[:WORD, "ab"]])
    ensure
      Object.send(:remove_const, :GeneratedPropertyDfaLexer) if
        Object.const_defined?(:GeneratedPropertyDfaLexer, false)
    end
  end

  it "uses the vendored Unicode version in the DFA rather than the host regexp" do
    unassigned_in_snapshot = [0x18db8].pack("U")
    dfa = Flexr.compile_pattern(/\p{Cn}/)

    expect(Flexr::Unicode::Property.ranges("Cn").any? { |lo, hi| 0x18db8.between?(lo, hi) }).to be(true)
    expect(dfa.accept?(unassigned_in_snapshot)).to be(true)
  end

  it "constructs a shortest exact first-match counterexample from two DFAs" do
    first = Flexr.compile_pattern(/a/)
    second = Flexr.compile_pattern(/a{6}/)

    expect(Flexr::Automaton::Analysis.firstmatch_counterexample(first, second)).to eq("aaaaaa".b)
    expect(Flexr::Automaton::Analysis.firstmatch_counterexample(second, first)).to be_nil
  end

  it "shares Unicode byte prefixes before NFA construction" do
    parsed = Flexr::Regexp::Parser.new("\\p{L}+").parse
    normalized = Flexr::Regexp::Normalizer.new(parsed).normalize
    acceptance = Flexr::Automaton::Acceptance.new(
      rule_index: 0, pattern_index: 0, bol_only: false, end_anchor: false
    )
    nfa = Flexr::Automaton::NFABuilder.new.build([[normalized, acceptance]])

    expect(nfa.states.length).to be < 4_000
  end
end
