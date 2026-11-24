# frozen_string_literal: true

require "flexr/automaton/token_diff"

RSpec.describe "automaton token differences" do
  def compare(left, right, encoding: Encoding::UTF_8, limit: 100_000)
    Flexr::Automaton::TokenDiff.compare(left.call, right.call, encoding: encoding, limit: limit)
  end

  def machine(encoding: Encoding::UTF_8, keywords: {}, &definition)
    lambda do
      lexer = Class.new(Flexr::Lexer)
      lexer.encoding(encoding)
      lexer.class_eval(&definition) if definition
      compiled = lexer.compile!
      rules = compiled.rules.map do |rule|
        next rule unless rule.trailing && !rule.trailing_dfa

        copy = rule.dup
        copy.trailing_dfa = Flexr.compile_pattern(copy.trailing, encoding: encoding)
        copy
      end
      effects = rules.to_h { |rule| [rule.index, (rule.action[1] if rule.emit?)] }
      Flexr::Automaton::TokenDiff::Side.new(
        dfa: compiled.machines.fetch(:initial).dfa, rules: rules, effects: effects,
        keyword_effects: keywords, allow_empty_match: lexer.__flexr_config.options[:allow_empty_match] == true
      )
    end
  end

  it "finds the shortest input where the winning token length changes" do
    left = machine { rule(/1/, emit: :INTEGER) }
    right = machine { rule([/1/, /1\./], emit: :INTEGER) }

    result = compare(left, right)

    expect([result.status, result.input, result.offset]).to eq([:different, "1.", 0])
    expect([result.left.length, result.right.length]).to eq([1, 2])
  end

  it "proves equal token behavior across rule indexes and DFA shapes" do
    left = machine { rule(/ab|ac/, emit: :LABEL) }
    right = machine do
      rule(/ab/, emit: :LABEL)
      rule(/ac/, emit: :LABEL)
    end

    expect(compare(left, right).status).to eq(:equal)
  end

  it "finds the effect of a keyword remap even when body DFAs agree" do
    left = machine { rule(/[a-z]+/, emit: :IDENT) }
    right = machine(keywords: { 0 => { "if" => :CONTROL } }) { rule(/[a-z]+/, emit: :IDENT) }

    result = compare(left, right)

    expect([result.status, result.input]).to eq([:different, "if"])
    expect([result.left.effect, result.right.effect]).to eq(%i[IDENT CONTROL])
  end

  it "never reports equality when an opaque action can win" do
    left = machine { rule(/a/) { skip } }
    right = machine { rule(/a/, emit: :A) }

    expect(compare(left, right).status).to eq(:inconclusive)
  end

  it "continues past opaque actions to find a later definite witness" do
    left = machine do
      rule(/a/) { skip }
      rule(/bb/, emit: :B)
    end
    right = machine do
      rule(/a/, emit: :A)
      rule(/bb/, emit: :C)
    end

    result = compare(left, right)
    expect([result.status, result.input]).to eq([:different, "bb"])
  end

  it "returns an inconclusive result when the search reaches its limit" do
    left = machine { rule(/b/, emit: :LABEL) }
    right = machine { rule(/a/, emit: :LABEL) }

    expect(compare(left, right, limit: 1).status).to eq(:inconclusive)
  end

  it "reports complete UTF-8 and supports arbitrary binary bytes" do
    text = compare(machine { rule(/é/, emit: :LABEL) }, machine)
    binary = compare(
      machine(encoding: Encoding::BINARY) { rule("\xff".b, emit: :LABEL) },
      machine(encoding: Encoding::BINARY), encoding: Encoding::BINARY
    )

    expect([text.status, text.input, text.left.length]).to eq([:different, "é", 2])
    expect([binary.status, binary.input, binary.input.encoding]).to eq([:different, "\xff".b, Encoding::BINARY])
  end

  it "resolves right assertions against the complete input suffix" do
    left = machine { rule(/a(?=bc)/, emit: :A) }
    right = machine { rule(/a(?=bd)/, emit: :A) }

    result = compare(left, right)

    expect([result.status, result.input, result.offset]).to eq([:different, "abc", 0])
    expect(result.left.length).to eq(1)
    expect(result.right).to be_nil
  end

  it "distinguishes end of line from end of source" do
    left = machine { rule(/a$/, emit: :A) }
    right = machine { rule(/a\z/, emit: :A) }

    result = compare(left, right)

    expect([result.status, result.input, result.left.length]).to eq([:different, "a\n", 1])
    expect(result.right).to be_nil
  end

  it "finds a witness after a preceding token-sized input prefix" do
    left = machine { rule(/(?<=a)b/, emit: :B) }

    result = compare(left, machine)

    expect([result.status, result.input, result.offset]).to eq([:different, "ab", 1])
    expect(result.left.length).to eq(1)
  end

  it "uses the full trailing context length to choose a shorter token body" do
    left = machine do
      rule(/ab/, emit: :LONG)
      rule(/a/, followed_by: /bc+/, emit: :SHORT)
    end
    right = machine do
      rule(/ab/, emit: :LONG)
      rule(/a/, followed_by: /bd+/, emit: :SHORT)
    end

    result = compare(left, right)

    expect([result.status, result.input]).to eq([:different, "abc"])
    expect([result.left.effect, result.left.length, result.right.effect, result.right.length]).to eq([:SHORT, 1, :LONG, 2])
  end

  it "proves equal word-boundary behavior across possible input prefixes" do
    left = machine do
      rule(/\bif\b/, emit: :IF)
      rule(/\w+/, emit: :IDENT)
    end
    right = machine do
      rule(/(?:\bif\b)/, emit: :IF)
      rule(/\w\w*/, emit: :IDENT)
    end

    expect(compare(left, right).status).to eq(:equal)
  end

  it "keeps atomic CRLF together for a grapheme body" do
    left = machine { rule(/\X/, emit: :CHAR) }
    right = machine { rule(/./m, emit: :CHAR) }

    result = compare(left, right)

    expect([result.status, result.input]).to eq([:different, "\r\n"])
    expect([result.left.length, result.right.length]).to eq([2, 1])
  end

  it "uses the later body end when one rule can reach the same trailing end twice" do
    left = machine { rule(/a+/, followed_by: /a*b/, emit: :A) }
    right = machine { rule(/a/, followed_by: /a*b/, emit: :A) }

    result = compare(left, right)

    expect([result.status, result.input]).to eq([:different, "aab"])
    expect([result.left.length, result.right.length]).to eq([2, 1])
  end

  it "proves contextual equality when a trailing runner loops" do
    left = machine { rule(/a/, followed_by: /b+/, emit: :A) }
    right = machine { rule(/a(?=b)/, emit: :A) }

    expect(compare(left, right).status).to eq(:equal)
  end
end
