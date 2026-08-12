# frozen_string_literal: true

require "spec_helper"

RSpec.describe Flexr::Source::PrismReader do
  def write_spec(name, source)
    path = File.join(Dir.tmpdir, "flexr-#{name}-#{Process.pid}.flexr.rb")
    File.binwrite(path, source)
    path
  end

  it "resolves module constants both lexically and with qualification" do
    path = write_spec("module-scope", <<~RUBY)
      require "flexr"

      module PrismModuleScopeRegression
        WORD = /a/
        QUALIFIED = /b/

        class Lexer < Flexr::Lexer
          rule(WORD) { emit :WORD }
          rule(PrismModuleScopeRegression::QUALIFIED) { emit :QUALIFIED }
        end
      end
    RUBY
    output = "#{path}.generated.rb"

    Flexr::Generator.new(path, output: output).generate
    load output

    expect(PrismModuleScopeRegression::Lexer.new("ab").tokens).to eq(
      [[:WORD, "a"], [:QUALIFIED, "b"]]
    )
  ensure
    FileUtils.rm_f(path) if path
    FileUtils.rm_f(output) if output
  end

  it "preserves class-scope constant resolution" do
    path = write_spec("class-scope", <<~RUBY)
      require "flexr"

      class PrismClassScopeRegressionLexer < Flexr::Lexer
        WORD = /c/
        rule(WORD) { emit :WORD }
      end
    RUBY
    output = "#{path}.generated.rb"

    Flexr::Generator.new(path, output: output).generate
    load output

    expect(PrismClassScopeRegressionLexer.new("c").tokens).to eq([[:WORD, "c"]])
  ensure
    FileUtils.rm_f(path) if path
    FileUtils.rm_f(output) if output
  end

  it "keeps dynamic constants as FLEXR-E017 in static generation" do
    path = write_spec("dynamic-scope", <<~RUBY)
      require "flexr"

      module PrismDynamicScopeRegression
        WORD = Time.now

        class Lexer < Flexr::Lexer
          rule(WORD) { emit :WORD }
        end
      end
    RUBY

    expect { Flexr::Generator.new(path).generate }
      .to raise_error(Flexr::StaticResolutionError) { |error|
        expect(error.diagnostic.code).to eq("FLEXR-E017")
      }
  ensure
    FileUtils.rm_f(path) if path
  end

  it "resolves constants and splats in Ruby source order" do
    path = write_spec("source-order", <<~RUBY)
      require "flexr"
      class PrismSourceOrderLexer < Flexr::Lexer
        PATTERNS = [/a/, /b/]
        rule([*PATTERNS]) { emit :KNOWN }
        rule(LATER) { emit :LATER }
        LATER = /c/
      end
    RUBY

    expect { Flexr::Generator.new(path).generate }
      .to raise_error(Flexr::StaticResolutionError) { |error|
        expect(error.diagnostic.code).to eq("FLEXR-E017")
        expect(error.diagnostic.note).to include("constant LATER")
      }
  ensure
    FileUtils.rm_f(path) if path
  end

  it "does not resolve constants assigned only by a rule action" do
    path = write_spec("action-constant", <<~RUBY)
      require "flexr"
      class PrismActionConstantLexer < Flexr::Lexer
        rule(/a/) { ACTION_ONLY = /b/ }
        rule(ACTION_ONLY) { emit :B }
      end
    RUBY

    expect { Flexr::Generator.new(path).generate }
      .to raise_error(Flexr::StaticResolutionError) { |error|
        expect(error.diagnostic.note).to include("constant ACTION_ONLY")
      }
  ensure
    FileUtils.rm_f(path) if path
  end

  it "preserves regexp options in interpolation and flattens pattern splats" do
    path = write_spec("interpolation", <<~'RUBY')
      require "flexr"
      class PrismInterpolationLexer < Flexr::Lexer
        INNER = /a/i
        PATTERNS = [/#{INNER}/, /b/]
        rule([*PATTERNS]) { emit :MATCH }
      end
    RUBY
    output = "#{path}.generated.rb"

    parsed = described_class.new(File.binread(path), path: path).read
    expect(parsed.rules.first.patterns.length).to eq(2)
    expect(parsed.rules.first.patterns.first).to match("A")
    Flexr::Generator.new(path, output: output).generate
    load output
    expect(PrismInterpolationLexer.new("Ab").tokens).to eq([[:MATCH, "A"], [:MATCH, "b"]])
  ensure
    Object.send(:remove_const, :PrismInterpolationLexer) if Object.const_defined?(:PrismInterpolationLexer, false)
    FileUtils.rm_f(path) if path
    FileUtils.rm_f(output) if output
  end

  it "fails closed for unsupported DSL shapes and unknown keywords" do
    cases = {
      receiver: <<~RUBY,
        class PrismReceiverLexer < Flexr::Lexer
          self.rule(/a/) { emit :A }
        end
      RUBY
      conditional: <<~RUBY,
        class PrismConditionalLexer < Flexr::Lexer
          if true
            rule(/a/) { emit :A }
          end
        end
      RUBY
      keyword: <<~RUBY
        class PrismKeywordLexer < Flexr::Lexer
          rule(/a/, typo: true) { emit :A }
        end
      RUBY
    }

    cases.each do |name, body|
      path = write_spec("unsupported-#{name}", %(require "flexr"\n#{body}))
      expect { Flexr::Generator.new(path).generate }
        .to raise_error(Flexr::StaticResolutionError) { |error|
          expect(error.diagnostic.code).to eq("FLEXR-E017")
        }
      FileUtils.rm_f(path)
    end
  end

  it "rejects a state without a block and ambiguous lexer classes" do
    no_block = write_spec("state-no-block", <<~RUBY)
      class PrismStateNoBlockLexer < Flexr::Lexer
        state :word
        rule(/a/) { emit :A }
      end
    RUBY
    expect { Flexr::Generator.new(no_block).generate }.to raise_error(ArgumentError, /requires a block/)

    ambiguous = write_spec("ambiguous", <<~RUBY)
      class PrismFirstLexer < Flexr::Lexer
        rule(/a/) { emit :A }
      end
      class PrismSecondLexer < Flexr::Lexer
        rule(/b/) { emit :B }
      end
    RUBY
    expect { Flexr::Generator.new(ambiguous).generate }
      .to raise_error(Flexr::StaticResolutionError) { |error| expect(error.diagnostic.code).to eq("FLEXR-E017") }
  ensure
    FileUtils.rm_f(no_block) if no_block
    FileUtils.rm_f(ambiguous) if ambiguous
  end

  it "statically evaluates hashes and absolute Encoding constants" do
    evaluate = lambda do |expression, constants: {}|
      node = Prism.parse(expression).value.statements.body.first
      Flexr::Source::StaticEval.new(expression, constants: constants).call(node)
    end

    expect(evaluate.call('{a: 1, "b" => 2, **EXTRA}', constants: { "EXTRA" => { c: 3 } }))
      .to eq({ a: 1, "b" => 2, c: 3 })
    expect(evaluate.call("::Encoding::UTF_8")).to eq(Encoding::UTF_8)
    expect(evaluate.call("/\#{/a/i}/")).to match("A")
    expect { evaluate.call("/\#{ 1; 2 }/") }.to raise_error(Flexr::StaticResolutionError, /statically resolvable/)
  end
end
