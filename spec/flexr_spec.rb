# frozen_string_literal: true

RSpec.describe Flexr do
  it "has a version number" do
    expect(Flexr::VERSION).not_to be nil
  end

  it "tokenizes a longest matching rule" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/[0-9]+/) { emit :INT, text.to_i }
      rule(/[ \t]+/, skip: true)
      rule(/\+/) { emit :PLUS }
    end

    expect(lexer_class.new("12 + 3").tokens).to eq([[:INT, 12], [:PLUS, "+"], [:INT, 3]])
  end

  it "keeps a later shorter rule from winning" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/ab/) { emit :SHORT }
      rule(/abc/) { emit :LONG }
    end

    expect(lexer_class.new("abc").tokens).to eq([[:LONG, "abc"]])
  end

  it "supports states" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/"/) { push :string }
      state :string do
        rule(/[^"\\]+/) { @value = text }
        rule(/"/) { value = @value; pop; emit :STRING, value }
      end
    end

    expect(lexer_class.new('"hello"').tokens).to eq([[:STRING, "hello"]])
  end

  it "provides diagnostics for unsupported regexp features" do
    expect { Flexr::Regexp::Parser.new("a(?=b)").parse }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E014")
      expect(error.diagnostic.help).to include("followed_by")
    end
  end

  it "generates source while preserving constants and actions" do
    path = File.expand_path("fixtures/generated.flexr.rb", __dir__)
    output = File.join(Dir.tmpdir, "flexr-generated-test.rb")
    Flexr::Generator.new(path, output: output).generate
    generated = File.read(output)
    expect(generated).to include("DIGIT = /[0-9]/")
    expect(generated).not_to include("rule(/")
    load output
    expect(GeneratedFixture::Lexer.new("42").tokens).to eq([[:INT, 42]])
  ensure
    FileUtils.rm_f(output) if output
  end

  it "supports EOF actions and Unicode properties" do
    load File.expand_path("fixtures/eof.flexr.rb", __dir__)
    expect(EofFixture::Lexer.new("ok").tokens).to eq([[:WORD, "ok"], [:EOF_TOKEN, :done]])

    lexer_class = Class.new(Flexr::Lexer) { rule(/[\p{Hiragana}]+/) { emit :WORD } }
    expect(lexer_class.new("あいう").tokens).to eq([[:WORD, "あいう"]])
  end
end
