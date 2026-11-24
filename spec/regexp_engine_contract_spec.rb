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
    %w[\\q \\g<name> \\X \\cA \\M-a].each do |source|
      expect { Flexr::Regexp::Parser.new(source).parse }
        .to raise_error(Flexr::UnsupportedRegexpError) do |error|
          expect(error.diagnostic.code).to eq("FLEXR-E014")
        end
    end
    expect { Flexr::Regexp::Parser.new("\\.").parse }.not_to raise_error
  end

  it "shows a literal rewrite example for an unknown escape" do
    expect { Flexr::Regexp::Parser.new('\\q').parse }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E014")
      expect(error.diagnostic.help).to include('rule(/q/)', "if q is literal", "keep the action")
    end

    expect(Flexr.compile_pattern(/\x09/).accept?("\t")).to be(true)
    expect(Flexr.compile_pattern(/\x09/).accept?("0")).to be(false)
    expect(Flexr.compile_pattern(/q/).accept?("q")).to be(true)
  end

  {
    /foo\b:/ => [/foo:/, "surrounding literals already establish the boundary"],
    /foo\Bbar/ => [/foobar/, "surrounding literals already establish the non-boundary"],
    /\Ga/ => [/a/, "at the start of a rule"],
    /\Aa/ => [/^a/, "input without line feeds"],
    /a\z/ => [/a$/, "input without line feeds"],
    /a\Z/ => [/a$/, "input without line feeds"]
  }.each do |original, (rewritten, condition)|
    it "shows a scoped boundary rewrite for #{original.inspect}" do
      expect { Flexr.parse_pattern(original) }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
        expect(error.diagnostic.code).to eq("FLEXR-E014")
        expect(error.diagnostic.help).to include("rule(#{original.inspect})", "rule(#{rewritten.inspect})",
                                                 condition, "keep the action")
      end
    end

    it "preserves token text and actions within the scope of the #{original.inspect} rewrite" do
      inputs = ["", "a", "aa", "ba", "ab", "foo:", "foobar", "xfoo:foobar", "éa"]
      inputs += ["a\na", "foo:\nfoobar"] unless %w[\\A \\z \\Z].any? { |anchor| original.source.include?(anchor) }
      reference = Regexp.new("\\G(?:#{original.source})")
      %i[table direct auto firstmatch].each do |backend|
        lexer = Class.new(Flexr::Lexer) do
          backend backend
          option :experimental if backend == :firstmatch
          rule(rewritten) { emit :MATCH }
          rule(/./m) { emit :OTHER }
        end

        inputs.each do |input|
          expected = []
          offset = 0
          while offset < input.length
            match = reference.match(input, offset)
            text = match ? match[0] : input[offset]
            expected << [match ? :MATCH : :OTHER, text.bytes]
            offset += text.length
          end

          [input, StringIO.new(input)].each do |source|
            actual = lexer.new(source, chunk_size: 1).tokens.map { |type, text| [type, text.bytes] }
            expect(actual).to eq(expected), "#{original.inspect} on #{input.inspect} with #{backend}"
          end
        end
      end
    end
  end

  it "keeps the limits of boundary rewrites explicit" do
    [/foo\b:/, /foo\Bbar/].each do |pattern|
      expect { Flexr.parse_pattern(pattern) }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
        expect(error.diagnostic.help).to include("token edges need separate rules or state checks")
      end
    end
    [/\Aa/, /a\z/, /a\Z/].each do |pattern|
      expect { Flexr.parse_pattern(pattern) }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
        expect(error.diagnostic.help).to include("line boundaries differ from string boundaries")
      end
    end
    expect { Flexr.parse_pattern(/a\Gb/) }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
      expect(error.diagnostic.help).to include('interior \G needs a separate rewrite')
    end

    expect(/\Aa/.match("b\na")).to be_nil
    expect(/^a/.match("b\na")[0]).to eq("a")
    expect(/a\z/.match("a\n")).to be_nil
    expect(/a\Z/.match("a\nb")).to be_nil
    expect(/a$/.match("a\nb")[0]).to eq("a")
    expect(Flexr.compile_pattern(/[\b]/).accept?("\b")).to be(true)
  end

  it "treats unsupported literal escapes inside character classes separately" do
    %w[A B G z Z K g X].each do |char|
      original = Regexp.new("[\\#{char}]")
      rewritten = Regexp.new("[#{char}]")
      expect { Flexr.parse_pattern(original) }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
        expect(error.diagnostic.code).to eq("FLEXR-E014")
        expect(error.diagnostic.help).to include("rule(#{original.inspect})", "rule(#{rewritten.inspect})",
                                                 "literal character", "keep the action")
        expect(error.diagnostic.help).not_to include("state checks", "input without line feeds", "lexer position")
      end

      dfa = Flexr.compile_pattern(rewritten)
      %w[A B G z Z K g X x].each { |input| expect(dfa.accept?(input)).to eq(original.match?(input)) }
    end
  end

  { Encoding::UTF_8 => /\R/, Encoding::BINARY => /\R/n }.each do |encoding, pattern|
    %i[table direct auto firstmatch].each do |backend|
      it "preserves #{encoding} line breaks and CRLF with #{backend}" do
        lexer = Class.new(Flexr::Lexer) do
          encoding encoding
          backend backend
          option :experimental if backend == :firstmatch
          rule(pattern) { emit :NEWLINE }
          rule(/./m, skip: true)
        end
        input = "\r\n\r\n\n\v\f\r\u0085\u2028\u2029x\t\u0086"
        input = input.b if encoding == Encoding::BINARY
        expected = input.scan(pattern).map { |text| [:NEWLINE, text.bytes] }

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

  it "treats both named group notations as transparent for the DFA without allowing backreferences" do
    [/(?<word>ab)/, /(?'word'ab)/].each do |pattern|
      dfa = Flexr.compile_pattern(pattern)
      expect(dfa.accept?("ab")).to be true
      expect(dfa.accept?("abb")).to be false
    end

    expect { Flexr.parse_pattern(/(?<word>a)\k<word>/) }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E014")
      expect(error.diagnostic.message).to include("backreferences")
      expect(error.diagnostic.help).to include("split the rule", "compare matched text")
    end
  end

  it "shows a conditional rewrite with an explicit limit on its use" do
    expect { Flexr.parse_pattern(/(a)?(?(1)b|c)/) }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E014")
      expect(error.diagnostic.help).to include("rule(/(a)?(?(1)b|c)/)", "rule(/(?:ab|c)/)",
                                               "other conditions need separate rules or state checks", "keep the action")
    end
  end

  it "agrees with Ruby on an absence group excluding nonempty alternatives" do
    dfa = Flexr.compile_pattern(/(?~(?:ab|bb))/, options: { allow_empty_match: true })
    reference = /\A(?~(?:ab|bb))\z/
    (0..4).each do |length|
      %W[a b é \n].repeated_permutation(length) do |characters|
        input = characters.join
        expect(dfa.accept?(input)).to eq(reference.match?(input)), input.inspect
      end
    end
  end

  it "defines absence by the excluded language when Ruby chooses a different match" do
    nullable = Flexr.compile_pattern(/(?~a?)/)
    expect(nullable.accept?("")).to be(false)
    expect(nullable.accept?("bbb")).to be(false)

    alternation = Flexr.compile_pattern(/x(?~a|b)/)
    expect(alternation.accept?("xé\n")).to be(true)
    expect(alternation.accept?("xca")).to be(false)
    expect(alternation.accept?("xcb")).to be(false)

    nesting = Flexr.compile_pattern(/x(?~(?~ab))/)
    expect(nesting.accept?("x")).to be(false)
  end

  it "restricts absence to whole UTF-8 scalars or binary bytes as configured" do
    utf8 = Flexr.compile_pattern(/x(?~é)/)
    expect(utf8.accept?("xあ")).to be(true)
    expect(utf8.accept?("xé")).to be(false)
    expect(utf8.accept?("x\xC3".b)).to be(false)
    expect(utf8.accept?("x\xE0\x80\x80".b)).to be(false)
    expect(utf8.accept?("x\xED\xA0\x80".b)).to be(false)
    expect(utf8.accept?("x\xF0\x80\x80\x80".b)).to be(false)
    expect(utf8.accept?("x\xF4\x90\x80\x80".b)).to be(false)
    expect(utf8.accept?("x\xFF".b)).to be(false)

    binary = Flexr.compile_pattern(/x(?~\xFF)/n)
    expect(binary.accept?("x\x80\x00".b)).to be(true)
    expect(binary.accept?("x\xFF".b)).to be(false)

    utf8_with_byte_expression = Flexr.compile_pattern(/x(?~\xFF)/n, encoding: Encoding::UTF_8)
    expect(utf8_with_byte_expression.accept?("xé")).to be(true)
    expect(utf8_with_byte_expression.accept?("x\x80".b)).to be(false)
  end

  it "reports empty matches, nested anchors, and limits for absence operations" do
    expect { Flexr.compile_pattern(/(?~ab)/) }.to raise_error(Flexr::CompileError) { |error|
      expect(error.diagnostic.code).to eq("FLEXR-E005")
    }
    expect { Flexr.compile_pattern(/x(?~^ab)/) }.to raise_error(Flexr::CompileError) { |error|
      expect(error.diagnostic.code).to eq("FLEXR-E009")
    }
    expect { Flexr.compile_pattern(/x(?~ab)/, options: { max_dfa_states: 3 }) }.to raise_error(Flexr::CompileError) { |error|
      expect(error.diagnostic.code).to eq("FLEXR-E006")
      expect(error.diagnostic.message).to include("absence")
    }
  end

  it "reports an empty absence language separately from a shadowed rule" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a(?~b?)/, emit: :IMPOSSIBLE)
      rule(/a/, emit: :A)
    end
    lexer.compile!
    diagnostic = lexer.__flexr_compiled.diagnostics.find { |item| item.code == "FLEXR-W001" }
    expect(diagnostic.note).to include('""', "every string")
  end

  it "rejects firstmatch body rules with absence rather than using Ruby's different semantics" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/x(?~a|b)/, emit: :MATCH)
    end
    expect { lexer.compile! }.to raise_error(Flexr::UnsupportedRegexpError) { |error|
      expect(error.diagnostic.code).to eq("FLEXR-E014")
      expect(error.diagnostic.help).to include("backend :table")
    }
  end

  it "preserves accepted input and token text in the suggested group rewrites" do
    {
      /(a)?(?(1)b|c)/ => /(?:ab|c)/,
      /x(?~a)/ => /x[^a]*/
    }.each do |original, rewritten|
      dfa = Flexr.compile_pattern(rewritten)
      full_match = Regexp.new("\\A(?:#{original.source})\\z")
      prefix_match = Regexp.new("\\A(?:#{original.source})")
      lexer = Class.new(Flexr::Lexer) do
        rule(rewritten) { emit :MATCH }
        rule(/./m) { emit :OTHER }
      end

      ["", "a", "b", "ab", "c", "ac", "abc", "x", "xa", "xb", "xbax", "x\na", "xé"].each do |input|
        expect(dfa.accept?(input)).to eq(full_match.match?(input)), "#{original.inspect} on #{input.inspect}"
        match = prefix_match.match(input)
        expected = match ? [:MATCH, match[0]] : ([:OTHER, input[0]] unless input.empty?)
        expect(lexer.new(input).next_token).to eq(expected)
      end
    end
  end

  it "agrees with Ruby on octal escapes and the digits that follow them" do
    {
      /\011+/ => %W[\t \t\t 011],
      /\0/ => ["\0", "0"],
      /\018/ => ["\x018", "\x0e"],
      /\08/ => ["\x008", "\b"],
      /\10/ => ["\b", "10"],
      /\18/ => ["\x018", "\x10"],
      /\1234/ => %w[S4 S],
      /\89/ => %w[89 9],
      /\0 11/x => ["\x0011", "\t"],
      /[\1-\3\89]/ => ["\x01", "\x02", "\x03", "\x04", "1", "8", "9"],
      /\303\251+/ => ["é", "éé", "Ã©", "e"],
      /\xC3\251|\303\xA9/ => %w[é e],
      /[\303\250-\303\252]/ => %w[é ê ë],
      /[\200-\377]/n => ["\x80".b, "\xff".b, "\x7f".b],
      /\377/n => ["\xff".b, "\xef".b],
      /[\101\300]/ni => ["A".b, "a".b, "\xc0".b, "\xe0".b],
      /\101\300/ni => ["A\xc0".b, "a\xc0".b, "A\xe0".b],
      /\101/i => %w[A a b]
    }.each do |pattern, inputs|
      full_match = Regexp.new("\\A(?:#{pattern.source})\\z", pattern.options)
      dfa = Flexr.compile_pattern(pattern)
      inputs.each do |input|
        expect(dfa.accept?(input)).to eq(full_match.match?(input)), "#{pattern.inspect} on #{input.inspect}"
      end
    end
  end

  it "distinguishes numbered references from octal escapes using preceding captures" do
    captures = "(a)" * 10
    reference = Regexp.new("#{captures}\\10")
    expect { Flexr.compile_pattern(reference) }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E014")
      expect(error.diagnostic.help).to include("capture limited")
    end
    expect(Flexr.compile_pattern(Regexp.new("\\10#{captures}")).accept?("\b#{'a' * 10}")).to be(true)
    expect(Flexr.compile_pattern(Regexp.new("#{captures}\\010")).accept?("#{'a' * 10}\b")).to be(true)

    source = "#{'(a)' * 1001}\\1001"
    expect(Regexp.new("\\A(?:#{source})\\z").match?("#{'a' * 1001}@1")).to be(true)
    ast = Flexr::Regexp::Parser.new(source).parse
    expect(ast.children.last(2).map(&:lo)).to eq("@1".bytes)
  end

  it "rejects an oversized octal byte and incomplete UTF-8 in raw parser sources" do
    ['\400', '\303', '\303\101'].each do |source|
      expect { Flexr::Regexp::Parser.new(source).parse }.to raise_error(Flexr::CompileError) do |error|
        expect(error.diagnostic.code).to eq("FLEXR-E001")
      end
    end
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
