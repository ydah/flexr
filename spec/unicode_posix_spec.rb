# frozen_string_literal: true

RSpec.describe "Unicode POSIX and property matching" do
  it "matches Ruby for Unicode POSIX classes" do
    {
      "alnum" => "あ",
      "alpha" => "あ",
      "blank" => "　",
      "cntrl" => "\x01",
      "digit" => "١",
      "graph" => "—",
      "lower" => "é",
      "print" => "あ",
      "punct" => "—",
      "space" => "　",
      "upper" => "Ω",
      "xdigit" => "A"
    }.each do |name, input|
      pattern = Regexp.new("[[:#{name}:]]")
      expected = Regexp.new("\\A(?:#{pattern.source})\\z", pattern.options).match?(input)

      expect(Flexr.compile_pattern(pattern).accept?(input)).to eq(expected)
    end
  end

  it "uses the vendored UCD as the POSIX and property oracle" do
    cases = [
      [/[[:alpha:]]/, [0x345].pack("U")],
      [/\p{L}/, [0x18db8].pack("U")],
      [/\P{Cn}/, [0xea944].pack("U")]
    ]

    cases.each do |pattern, input|
      reference = Flexr::Unicode::ReferenceRegexp.compiled(
        pattern, encoding: pattern.encoding, options: pattern.options, unicode: false
      )
      match = reference.match(input, 0)
      expected = match&.begin(0) == 0 && match[0].bytesize == input.bytesize

      expect(Flexr.compile_pattern(pattern).accept?(input)).to eq(expected)
    end
  end

  it "supports inner-negated POSIX classes" do
    cases = {
      "[[:^alpha:]]" => [["1", true], ["a", false]],
      "[[:^digit:]]" => [["a", true], ["١", false]],
      "[[:^space:]]" => [["a", true], ["　", false]]
    }

    cases.each do |source, examples|
      dfa = Flexr.compile_pattern(Regexp.new(source))
      examples.each { |input, expected| expect(dfa.accept?(input)).to eq(expected) }
    end
  end

  it "keeps Unicode shorthand ASCII-based in BINARY mode" do
    {
      "d" => [["5", true], ["A", false]],
      "w" => [["A", true], ["!", false]],
      "s" => [[" ", true], ["A", false]]
    }.each do |shorthand, examples|
      pattern = Regexp.new("[\\#{shorthand}\\xFF]".b)
      dfa = Flexr.compile_pattern(pattern, options: { unicode: true })
      examples.each { |input, expected| expect(dfa.accept?(input.b)).to eq(expected) }
    end
  end

  it "resolves Unicode property aliases independent of case and separators" do
    cases = {
      "digit" => %w[Nd ١ A],
      "DIGIT" => %w[Nd ١ A],
      "alpha" => %W[Alphabetic \u05b0 1],
      "ALPHA" => %w[Alphabetic あ 1],
      "al-num" => %W[Alnum \u05b0 _],
      "AL_NUM" => %w[Alnum あ _],
      "word" => ["Word", "_", " "],
      "WORD" => ["Word", "\u05b0", " "],
      "space" => ["Space", "　", "A"],
      "SPACE" => ["Space", "　", "A"],
      "lower-case" => %w[Lowercase a A],
      "UPPER_CASE" => %w[Uppercase A a]
    }

    cases.each do |name, (canonical, positive, negative)|
      expect(Flexr::Unicode::Property.ranges(name))
        .to eq(Flexr::Unicode::Property.ranges(canonical))
      dfa = Flexr.compile_pattern(Regexp.new("\\p{#{name}}"))
      expect(dfa.accept?(positive)).to be(true)
      expect(dfa.accept?(negative)).to be(false)
    end
  end

  it "includes UCD Other_Alphabetic in POSIX alpha and alnum" do
    other_alphabetic = Flexr::Unicode::Property.ranges("Other_Alphabetic")
    expect(other_alphabetic).not_to be_empty

    alpha = Flexr.compile_pattern(/[[:alpha:]]/)
    alnum = Flexr.compile_pattern(/[[:alnum:]]/)
    not_alpha = Flexr.compile_pattern(/[[:^alpha:]]/)
    [0x05b0, 0x093a].each do |codepoint|
      input = [codepoint].pack("U")
      expect(other_alphabetic.any? { |lo, hi| codepoint.between?(lo, hi) }).to be(true)
      expect(alpha.accept?(input)).to be(true)
      expect(alnum.accept?(input)).to be(true)
      expect(not_alpha.accept?(input)).to be(false)
    end
  end

  it "keeps core Unicode properties complete and UTF-8-safe" do
    covers = lambda do |name, codepoint|
      Flexr::Unicode::Property.ranges(name).any? { |lo, hi| codepoint.between?(lo, hi) }
    end

    expect(covers.call("Cn", 0x18db8)).to be(true)
    expect(covers.call("Assigned", 0x18db8)).to be(false)
    expect(covers.call("Lowercase", 0x61)).to be(true)
    expect(covers.call("Uppercase", 0x41)).to be(true)

    [/\p{Cn}/, /\p{Lowercase}/, /\p{Uppercase}/, /\p{Cs}/, /\p{C}/].each do |pattern|
      expect { Flexr.compile_pattern(pattern) }.not_to raise_error
    end
  end

  it "does not raise when a reference DFA receives valid UTF-8 bytes" do
    dfa = Flexr.compile_pattern(/\p{L}/)

    expect(dfa.accept?("あ".b)).to be(true)
  end

  it "keeps valid property alternatives when another candidate fails its anchor" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule([/\p{L}$/, /\p{L}/]) { emit :LETTER, text }
    end

    expect(lexer_class.new("ab").tokens).to eq([[:LETTER, "a"], [:LETTER, "b"]])
  end

  it "keeps POSIX matching in generated lexers" do
    path = File.join(Dir.tmpdir, "flexr-unicode-posix-#{Process.pid}.flexr.rb")
    output = "#{path}.generated.rb"
    File.binwrite(path, <<~RUBY)
      require "flexr"

      class UnicodePosixGeneratedLexer < Flexr::Lexer
        rule(/[[:alpha:]]+/) { emit :WORD }
        rule(/./) { emit :CHAR }
      end
    RUBY

    Flexr::Generator.new(path, output: output).generate
    load output

    expect(UnicodePosixGeneratedLexer.new("あ!").tokens)
      .to eq([[:WORD, "あ"], [:CHAR, "!"]])
  ensure
    FileUtils.rm_f(path) if path
    FileUtils.rm_f(output) if output
  end
end
