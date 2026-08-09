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
        rule(/"/) do value = @value
 pop
 emit :STRING, value end
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

  it "parses public patterns and rejects malformed regexp sources" do
    expect(Flexr.parse_pattern(/a+/)).to be_a(Flexr::Regexp::AST::Seq)

    expect { Flexr::Regexp::Parser.new("a)").parse }
      .to raise_error(Flexr::CompileError) { |error| expect(error.diagnostic.code).to eq("FLEXR-E001") }
    expect { Flexr::Regexp::Parser.new("\\x{}").parse }
      .to raise_error(Flexr::CompileError) { |error| expect(error.diagnostic.code).to eq("FLEXR-E001") }
  end

  it "rejects empty alternatives in every pattern of a rule" do
    lexer_class = Class.new(Flexr::Lexer) { rule([/a/, ""]) { emit :TOKEN } }

    expect { lexer_class.new("a").tokens }
      .to raise_error(Flexr::CompileError) { |error| expect(error.diagnostic.code).to eq("FLEXR-E005") }
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

  it "removes nested DSL spans as one source transformation" do
    spec = File.join(Dir.tmpdir, "flexr-state-source-#{Process.pid}.flexr.rb")
    output = File.join(Dir.tmpdir, "flexr-state-source-#{Process.pid}.rb")
    File.write(spec, <<~RUBY)
      require "flexr"
      module NestedSourceFixture
        class Lexer < Flexr::Lexer
          rule(/</) { more; push :tag; skip }
          state :tag do
            rule(/[^>]+/) { more; skip }
            rule(/>/) { pop; emit :TAG }
          end
        end
      end
    RUBY

    Flexr::Generator.new(spec, output: output).generate
    expect { RubyVM::InstructionSequence.compile(File.read(output)) }.not_to raise_error
    load output
    expect(NestedSourceFixture::Lexer.new("<value>").tokens).to eq([[:TAG, "<value>"]])
  ensure
    FileUtils.rm_f(spec)
    FileUtils.rm_f(output)
  end

  it "supports EOF actions and Unicode properties" do
    load File.expand_path("fixtures/eof.flexr.rb", __dir__)
    expect(EofFixture::Lexer.new("ok").tokens).to eq([[:WORD, "ok"], %i[EOF_TOKEN done]])

    lexer_class = Class.new(Flexr::Lexer) { rule(/\p{Hiragana}+/) { emit :WORD } }
    expect(lexer_class.new("あいう").tokens).to eq([[:WORD, "あいう"]])
  end
end
