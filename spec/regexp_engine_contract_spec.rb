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

  it "shows literal rewrite examples for octal and unknown escapes" do
    {
      '\\011' => ['rule(/\\x09/)', 'rule(/\\011/)'],
      '\\q' => ['rule(/q/)', "if q is literal"]
    }.each do |source, expected|
      expect { Flexr::Regexp::Parser.new(source).parse }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
        expect(error.diagnostic.code).to eq("FLEXR-E014")
        expect(error.diagnostic.help).to include(*expected, "keep the action")
      end
    end

    expect(Flexr.compile_pattern(/\x09/).accept?("\t")).to be(true)
    expect(Flexr.compile_pattern(/\x09/).accept?("0")).to be(false)
    expect(Flexr.compile_pattern(/q/).accept?("q")).to be(true)
  end

  {
    Encoding::UTF_8 => /\r\n|[\n\v\f\r\u0085\u2028\u2029]/,
    Encoding::BINARY => /\r\n|[\n\v\f\r]/n
  }.each do |encoding, replacement|
    it "shows a standalone line-break rule for #{encoding}" do
      lexer = Class.new(Flexr::Lexer) do
        encoding encoding
        rule(/\R/, emit: :NEWLINE)
      end

      expect { lexer.compile! }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
        expect(error.diagnostic.code).to eq("FLEXR-E014")
        expect(error.diagnostic.help).to include("standalone line-break token", "rule(#{replacement.inspect})", "keep the action")
      end
    end

    %i[table direct auto firstmatch].each do |backend|
      it "preserves #{encoding} line breaks and CRLF with #{backend}" do
        lexer = Class.new(Flexr::Lexer) do
          encoding encoding
          backend backend
          option :experimental if backend == :firstmatch
          rule(replacement) { emit :NEWLINE }
          rule(/./m, skip: true)
        end
        input = "\r\n\r\n\n\v\f\r\u0085\u2028\u2029x\t\u0086"
        input = input.b if encoding == Encoding::BINARY
        original = encoding == Encoding::BINARY ? /\R/n : /\R/
        expected = input.scan(original).map { |text| [:NEWLINE, text.bytes] }

        [input, StringIO.new(input)].each do |source|
          tokens = lexer.new(source, chunk_size: 1).tokens.map { |token, text| [token, text.bytes] }
          expect(tokens).to eq(expected)
        end
        expect(expected.first).to eq([:NEWLINE, [13, 10]])
        expect(expected.length).to eq(encoding == Encoding::BINARY ? 6 : 9)
      end
    end
  end

  it "shows a delimited-text rewrite for lazy and possessive quantifiers" do
    [/".*?"/, /"[^"\n]*+"/].each do |pattern|
      expect { Flexr.parse_pattern(pattern) }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
        expect(error.diagnostic.code).to eq("FLEXR-E014")
        expect(error.diagnostic.help).to include('rule(/"[^"\n]*"/)', "unescaped single-line quoted text",
                                                 "keep the action", "removing lazy or possessive modifiers can change matches")
      end
    end
  end

  it "shows a delimited-text rewrite for atomic groups with a limit on its use" do
    expect { Flexr.parse_pattern(/"(?>[^"\n]*)"/) }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E014")
      expect(error.diagnostic.help).to include('rule(/"[^"\n]*"/)', "unescaped single-line quoted text",
                                               "keep the action", "removing atomic groups can change matches")
    end
  end

  it "keeps the suggested quoted token at the first closing quote and rejects line breaks" do
    rewritten = /"[^"\n]*"/
    originals = [/".*?"/, /"[^"\n]*+"/, /"(?>[^"\n]*)"/]
    lexer = Class.new(Flexr::Lexer) do
      rule(rewritten) { emit :STRING }
      rule(/./m) { emit :OTHER }
    end

    ['""', '"a""b"', '"a" rest', "\"a\nb\"", '"unfinished'].each do |input|
      match = rewritten.match(input)
      expected = match ? [:STRING, match[0]] : [:OTHER, input[0]]
      originals.each { |pattern| expect(pattern.match(input)&.[](0)).to eq(match&.[](0)) }
      expect(lexer.new(input).next_token).to eq(expected)
    end
    expect(lexer.new('"a""b"').tokens).to eq([[:STRING, '"a"'], [:STRING, '"b"']])
  end

  it "shows a finite-choice rewrite for both backreference notations" do
    [/(a|b)\1/, /(a|b)\k<1>/].each do |pattern|
      expect { Flexr.parse_pattern(pattern) }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
        expect(error.diagnostic.code).to eq("FLEXR-E014")
        expect(error.diagnostic.help).to include('rule(/(a|b)\1/)', 'rule(/(?:aa|bb)/)',
                                                 "capture limited to a or b", "split the rule", "states", "keep the action")
      end
    end

    lexer = Class.new(Flexr::Lexer) do
      rule(/(?:aa|bb)/) { emit :PAIR }
      rule(/./) { emit :OTHER }
    end
    dfa = Flexr.compile_pattern(/(?:aa|bb)/)
    ["", "a", "b", "aa", "bb", "ab", "ba", "aaa", "aabb"].each do |input|
      expect(dfa.accept?(input)).to eq(/\A(a|b)\1\z/.match?(input))
    end
    expect(lexer.new("aabbab").tokens).to eq([[:PAIR, "aa"], [:PAIR, "bb"], [:OTHER, "a"], [:OTHER, "b"]])
  end

  it "treats an octal character-class escape separately from a backreference" do
    expect { Flexr.parse_pattern(/[\1]/) }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E014")
      expect(error.diagnostic.help).to include('rule(/[\x01]/)', "character code", "keep the action")
      expect(error.diagnostic.help).not_to include("capture limited", "aa|bb")
    end
    dfa = Flexr.compile_pattern(Regexp.new('[\x01]'))
    expect(dfa.accept?("\x01")).to be(true)
    expect(dfa.accept?("1")).to be(false)
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
