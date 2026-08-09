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
