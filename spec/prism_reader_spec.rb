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
end
