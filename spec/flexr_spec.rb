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

  it "uses the direct backend without changing longest-match results" do
    lexer_class = Class.new(Flexr::Lexer) do
      backend :direct
      rule(/[a-z]+/) { emit :WORD }
      rule(/[0-9]+/) { emit :NUMBER }
      rule(/[ \t]+/, skip: true)
    end

    expect(lexer_class.new("abc 12").tokens).to eq([[:WORD, "abc"], [:NUMBER, "12"]])
  end

  it "reports shadowed rules in compiler diagnostics" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a/) { skip }
      rule(/a/) { skip }
    end

    expect(lexer_class.compile!.diagnostics.map(&:code)).to include("FLEXR-W001")
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

  it "does not let state-local reference rules leak into initial" do
    lexer_class = Class.new(Flexr::Lexer) do
      state :word do
        rule(/\p{L}+/) { emit :WORD }
      end
      rule(/./) { emit :CHAR }
    end

    expect(lexer_class.new("a").tokens).to eq([[:CHAR, "a"]])
  end

  it "does not let state-local firstmatch rules leak into initial" do
    lexer_class = Class.new(Flexr::Lexer) do
      backend :firstmatch
      option :experimental
      state :word do
        rule(/a+/) { emit :WORD }
      end
      rule(/./) { emit :CHAR }
    end

    expect(lexer_class.new("a").tokens).to eq([[:CHAR, "a"]])
  end

  it "keeps anchor conditions local to each alternative pattern" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule([/^a/, /b/]) { emit :X }
      rule(/./) { emit :CHAR }
    end

    expect(lexer_class.new("!b").tokens).to eq([[:CHAR, "!"], [:X, "b"]])
  end

  it "diagnoses anchors nested inside regexp alternation" do
    [/^a|b/, /a|b$/].each do |pattern|
      expect { Flexr.compile_pattern(pattern) }
        .to raise_error(Flexr::CompileError) { |error| expect(error.diagnostic.code).to eq("FLEXR-E009") }
    end
  end

  it "consumes the separator in mixed inline regexp options" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/(?i-m:a)/) { emit :X }
      rule(/./) { emit :CHAR }
    end

    expect(lexer_class.new("A").tokens).to eq([[:X, "A"]])
  end

  it "preserves anchors around global inline options" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/(?i)^a$/) { emit :A }
      rule(/./) { emit :OTHER }
    end

    expect(lexer_class.new("a").tokens).to eq([[:A, "a"]])
    expect(lexer_class.new("A").tokens).to eq([[:A, "A"]])
  end

  it "provides diagnostics for unsupported regexp features" do
    expect { Flexr::Regexp::Parser.new("a(?=b)").parse }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E014")
      expect(error.diagnostic.help).to include("followed_by")
    end
  end

  it "reports parser limit and anchor diagnostics as compile errors" do
    expect { Flexr::Regexp::Parser.new("a{1001}").parse }
      .to raise_error(Flexr::CompileError) { |error| expect(error.diagnostic.code).to eq("FLEXR-E007") }
    expect { Flexr::Regexp::Parser.new("a^b").parse }
      .to raise_error(Flexr::CompileError) { |error| expect(error.diagnostic.code).to eq("FLEXR-E009") }
  end

  it "parses public patterns and rejects malformed regexp sources" do
    expect(Flexr.parse_pattern(/a+/)).to be_a(Flexr::Regexp::AST::Seq)
    expect(Flexr.compile_pattern(/[^a]/).accept?("あ")).to be(true)

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
    expect(generated).to include(
      "def scan_one", "def __flexr_generated_execute", "def __flexr_generated_accelerate",
      "Flexr::Automaton::Accel.extract"
    )
    expect(generated).not_to include("rule(/")
    load output
    expect(GeneratedFixture::Lexer.new("42").tokens).to eq([[:INT, 42]])
  ensure
    FileUtils.rm_f(output) if output
  end

  it "uses acceleration in generated binary lexers" do
    path = File.join(Dir.tmpdir, "flexr-generated-accel-#{Process.pid}.flexr.rb")
    output = "#{path}.generated.rb"
    File.write(path, <<~RUBY)
      require "flexr"

      class BinaryAccelFixture < Flexr::Lexer
        encoding Encoding::BINARY
        rule(/a+/) { emit :A }
        rule(/./) { emit :CHAR }
      end
    RUBY

    load path
    Object.send(:remove_const, :BinaryAccelFixture)
    Flexr::Generator.new(path, output: output).generate
    load output

    expect(Flexr::Automaton::Accel).to receive(:extract).and_call_original
    expect(BinaryAccelFixture.new("a".b * 100).tokens).to eq([[:A, "a".b * 100]])
  ensure
    Object.send(:remove_const, :BinaryAccelFixture) if Object.const_defined?(:BinaryAccelFixture, false)
    FileUtils.rm_f(path) if path
    FileUtils.rm_f(output) if output
  end

  it "preserves captured locals in generated action blocks" do
    path = File.join(Dir.tmpdir, "flexr-captured-action-#{Process.pid}.flexr.rb")
    output = "#{path}.generated.rb"
    File.write(path, <<~RUBY)
      require "flexr"

      class CapturedActionFixture < Flexr::Lexer
        value = 42
        rule(/a/) { emit :A, value }
      end
    RUBY

    load path
    runtime_tokens = CapturedActionFixture.new("a").tokens
    Object.send(:remove_const, :CapturedActionFixture)
    generated = Flexr::Generator.new(path, output: output).generate
    expect(generated).to include("instance_exec(&rule.action)")
    load output

    expect(CapturedActionFixture.new("a").tokens).to eq(runtime_tokens)
  ensure
    Object.send(:remove_const, :CapturedActionFixture) if Object.const_defined?(:CapturedActionFixture, false)
    FileUtils.rm_f(path) if path
    FileUtils.rm_f(output) if output
  end

  it "loads generated tables from the packed representation" do
    path = File.expand_path("fixtures/generated.flexr.rb", __dir__)
    output = File.join(Dir.tmpdir, "flexr-packed-test.rb")
    generated = Flexr::Generator.new(path, output: output, options: { table_format: :packed }).generate

    expect(generated).to include("encoding: :base64")
    expect(generated).not_to include("transitions:")
    load output
    expect(GeneratedFixture::Lexer.new("42").tokens).to eq([[:INT, 42]])
  ensure
    FileUtils.rm_f(output) if output
  end

  it "loads row-compressed generated tables without Base64 encoding" do
    path = File.expand_path("fixtures/generated.flexr.rb", __dir__)
    output = nil
    %i[rows full].each do |compression|
      output = File.join(Dir.tmpdir, "flexr-compressed-#{compression}-#{Process.pid}.rb")
      Flexr::Generator.new(path, output: output, options: { table_compression: compression }).generate
      load output
      expect(GeneratedFixture::Lexer.new("42").tokens).to eq([[:INT, 42]])
      FileUtils.rm_f(output)
    end
  ensure
    FileUtils.rm_f(output) if output
  end

  it "loads full compressed generated tables from Base64" do
    path = File.expand_path("fixtures/generated.flexr.rb", __dir__)
    output = File.join(Dir.tmpdir, "flexr-compressed-full-packed-#{Process.pid}.rb")
    generated = Flexr::Generator.new(path, output: output,
                                     options: { table_compression: :full, table_format: :packed }).generate

    expect(generated).to include("encoding: :base64", "fallback:")
    load output
    expect(GeneratedFixture::Lexer.new("42").tokens).to eq([[:INT, 42]])
  ensure
    FileUtils.rm_f(output) if output
  end

  it "loads the direct dispatch representation for generated direct lexers" do
    spec = File.join(Dir.tmpdir, "flexr-direct-#{Process.pid}.flexr.rb")
    output = File.join(Dir.tmpdir, "flexr-direct-#{Process.pid}.rb")
    File.write(spec, <<~RUBY)
      require "flexr"
      class GeneratedDirectFixture < Flexr::Lexer
        backend :direct
        rule(/</) { push :number; skip }
        rule(/[a-z]+/) { emit :WORD }
        state :number do
          rule(/[0-9]+/) { pop; emit :NUMBER }
        end
      end
    RUBY

    generated = Flexr::Generator.new(spec, output: output).generate

    expect(generated).to include("dispatch: :case", "case class_id")
    load output
    dfa = GeneratedDirectFixture.compile!.machines.fetch(:initial).dfa
    expect(dfa.direct).not_to be_nil
    expect(GeneratedDirectFixture.new("abc<123").tokens).to eq([[:WORD, "abc"], [:NUMBER, "123"]])
  ensure
    FileUtils.rm_f(spec) if spec
    FileUtils.rm_f(output) if output
  end

  it "aborts firstmatch generation when deterministic differential checks disagree" do
    spec = File.join(Dir.tmpdir, "flexr-firstmatch-#{Process.pid}.flexr.rb")
    File.write(spec, <<~RUBY)
      require "flexr"
      class FirstmatchFixture < Flexr::Lexer
        backend :firstmatch
        option :experimental
        rule(/a/) { emit :A }
        rule(/aa/) { emit :AA }
      end
    RUBY

    expect { Flexr::Generator.new(spec).generate }
      .to raise_error(Flexr::CompileError, /firstmatch differs from table/)
  ensure
    FileUtils.rm_f(spec) if spec
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

  it "supports UCD general-category and script properties" do
    lexer_class = Class.new(Flexr::Lexer) { rule(/\p{Lu}+/) { emit :UPPER } }
    expect(lexer_class.new("ABC").tokens).to eq([[:UPPER, "ABC"]])

    latin = Class.new(Flexr::Lexer) { rule(/\p{Latin}+/) { emit :LATIN } }
    expect(latin.new("abc").tokens).to eq([[:LATIN, "abc"]])
  end

  it "case-folds Unicode properties in reference rules" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/\p{Lu}/i) { emit :LETTER }
      rule(/./) { emit :OTHER }
    end

    expect(lexer_class.new("aA1").tokens).to eq([[:LETTER, "a"], [:LETTER, "A"], [:OTHER, "1"]])
  end

  it "splits singleton Unicode codepoints without admitting surrogates" do
    expect(Flexr::Unicode::Utf8Splitter.split(0x1f600, 0x1f600).first.map(&:first))
      .to eq("😀".bytes)
    expect(Flexr::Unicode::Utf8Splitter.split(0xd800, 0xd800)).to eq([])
  end

  it "uses simple case folding equivalence classes from the UCD" do
    lexer_class = Class.new(Flexr::Lexer) { rule(/k/i) { emit :K } }

    expect(lexer_class.new("K").tokens).to eq([[:K, "K"]])
  end

  it "preserves unrelated dynamic constants during generation" do
    spec = File.join(Dir.tmpdir, "flexr-dynamic-constant-#{Process.pid}.flexr.rb")
    File.write(spec, <<~RUBY)
      require "flexr"
      class DynamicConstantLexer < Flexr::Lexer
        HELPER = Time.now
        rule(/a/) { emit :A }
      end
    RUBY

    generated = Flexr::Generator.new(spec).generate
    expect(generated).to include("HELPER = Time.now")
    expect(generated).not_to include("rule(/a/)")
  ensure
    FileUtils.rm_f(spec) if spec
  end

  it "generates deterministic source despite compilation timing diagnostics" do
    path = File.expand_path("../examples/json/lexer.flexr.rb", __dir__)

    first = Flexr::Generator.new(path).generate
    second = Flexr::Generator.new(path).generate

    expect(second).to eq(first)
  end
end
