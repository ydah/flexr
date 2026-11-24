# frozen_string_literal: true

require "flexr/automaton/tagged_compiler"

RSpec.describe "lookahead tagged DFA captures" do
  def compile(regexp, **)
    Flexr::Automaton::TaggedCompiler.compile(regexp, **)
  end

  def ranges(program, input, offset: 0)
    cursor = program.cursor
    input.each_byte.with_index(offset) { |byte, position| cursor.advance(byte, position) }
    cursor.capture_ranges(offset + input.bytesize)
  end

  def ruby_ranges(regexp, input, offset)
    match = regexp.match(input)
    return unless match

    regexp.names.to_h do |name|
      first, last = match.byteoffset(name)
      [name, ((first + offset)...(last + offset) if first)]
    end
  end

  def reference(regexp, encoding: Encoding::UTF_8, unicode: false)
    Flexr::Unicode::ReferenceRegexp.compiled(regexp, encoding: encoding, unicode: unicode, anchored: true)
  end

  it "defers each tag write until the following byte or accepting endpoint selects its path" do
    first = compile(/(?<head>a|aa)(?<tail>a+)/).program
    second = compile(/(?<head>aa|a)(?<tail>a+)/).program

    expect(ranges(first, "aaa", offset: 10)).to eq("head" => 10...11, "tail" => 11...13)
    expect(ranges(second, "aaa", offset: 10)).to eq("head" => 10...12, "tail" => 12...13)
    expect(ranges(first, "a")).to be_nil
  end

  it "reads the accepting snapshot without advancing or changing live registers" do
    program = compile(/(?<word>a+)/).program
    expect(Ractor.shareable?(program)).to be(true)
    cursor = program.cursor
    other = program.cursor
    cursor.advance("a".ord, 0)
    expect(cursor.capture_ranges(1)).to eq("word" => 0...1)
    other.advance("a".ord, 20)
    cursor.advance("a".ord, 1)
    snapshot = cursor.capture_ranges(2)
    cursor.advance("a".ord, 2)
    expect(snapshot).to eq("word" => 0...2)
    expect(cursor.capture_ranges(3)).to eq("word" => 0...3)
    expect(other.capture_ranges(21)).to eq("word" => 20...21)
  end

  it "preserves Ruby's retained, empty, and duplicate captures" do
    fixtures = {
      /(?:(?<left>a)|b)+/ => %w[abb bba bbb],
      /(?<outer>a(?<inner>b)?)+/ => %w[aba ababa aa],
      /(?:(?<same>a)|(?<same>b))+c/ => %w[bac ac abc],
      /(?<before>)(?<optional>b)?(?<never>a){0}c/ => %w[c bc ac],
      /(?<one>a+)(?<two>a*)/ => %w[a aa aaa],
      /(?<choice>ab|a){1,3}(?<tail>b?)/ => %w[a ab abb abab]
    }
    fixtures.each do |regexp, inputs|
      result = compile(regexp)
      expect(result.reason).to be_nil, regexp.inspect
      expected = reference(regexp)
      inputs.each do |input|
        expect(ranges(result.program, input)).to eq(ruby_ranges(expected, input, 0)), "#{regexp.inspect} on #{input.inspect}"
      end
    end
  end

  it "reports byte ranges for UTF-8 and binary patterns" do
    [
      [/(?<prefix>é*)(?<item>😀)/, "éé😀", Encoding::UTF_8],
      [/(?<left>\xff+)(?<right>\x00)/n, "\xff\xff\x00".b, Encoding::BINARY]
    ].each do |regexp, input, encoding|
      result = compile(regexp, encoding: encoding)
      expect(result.reason).to be_nil
      expect(ranges(result.program, input)).to eq(ruby_ranges(reference(regexp, encoding: encoding), input, 0))
    end
  end

  it "compiles a repeated Unicode property within the default budgets" do
    pattern = /(?<word>\p{L}+)(?<digits>\d*)/
    result = compile(pattern)

    expect(result.reason).to be_nil
    expect(ranges(result.program, "日本é12")).to eq("word" => 0...8, "digits" => 8...10)
  end

  it "keeps the capture history that Ruby selects around a zero-byte iteration" do
    pattern = /(?:(?<first>a?)|(?<last>a?|b))*(?<atend>a)/
    result = compile(pattern)

    expect(result.reason).to be_nil
    expect(ranges(result.program, "ba")).to eq("first" => 0...0, "last" => 1...1, "atend" => 1...2)
    expect(ranges(result.program, "abba", offset: 4)).to eq(ruby_ranges(reference(pattern), "abba", 4))
  end

  it "returns explicit reasons when the search exceeds compiler budgets" do
    pattern = /(?<a>a)(?<b>b)(?<c>c)/
    expect(compile(pattern, max_states: 1)).to have_attributes(program: nil, reason: :state_limit)
    expect(compile(pattern, max_registers: 1)).to have_attributes(program: nil, reason: :register_limit)
  end

  it "does not silently compile lookaround as an ordinary consuming expression" do
    expect(compile(/(?<word>a)(?=b)/)).to have_attributes(program: nil, reason: :unsupported_context)
  end

  it "identifies nullable repetitions whose Ruby precedence needs replay" do
    [/(?<word>a?){2,3}b/, /(?<word>a?){2,}b/].each do |pattern|
      expect(compile(pattern)).to have_attributes(program: nil, reason: :nullable_repetition)
    end
  end

  it "agrees with selected-body replay on generated ambiguous patterns and inputs" do
    random = Random.new(0x7dfa)
    alphabet = %w[a b é]
    inputs = [""]
    (1..4).each { |length| inputs.concat(alphabet.repeated_permutation(length).map(&:join)) }
    choices = %w[a b é a|aa ab|a a|b é|éa a? a?|b b*]
    suffixes = %w[a b a? b* a+ a|ab é?]
    matches = 0
    misses = 0

    54.times do
      word = choices.sample(random: random)
      tail = suffixes.sample(random: random)
      quantifiers = %w[? + *]
      quantifiers << "{1,3}" unless word.match?(/[?*]/)
      quantifier = quantifiers.sample(random: random)
      regexp = Regexp.new("(?<first>(?<inner>#{word})#{quantifier})(?<last>#{tail})")
      expected = reference(regexp)
      result = compile(regexp)
      expect(result.reason).to be_nil, regexp.inspect
      inputs.each do |input|
        offset = random.rand(32)
        replayed = ruby_ranges(expected, input, offset)
        if replayed
          matches += 1
        else
          misses += 1
        end
        expect(ranges(result.program, input, offset: offset)).to eq(replayed), "#{regexp.inspect} on #{input.inspect}"
      end
    end
    expect(matches).to be > 100
    expect(misses).to be > 100
  end
end
