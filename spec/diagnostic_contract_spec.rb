# frozen_string_literal: true

require "spec_helper"

RSpec.describe "diagnostic contracts" do
  def write_spec(name, source)
    path = File.join(Dir.tmpdir, "flexr-diagnostic-#{name}-#{Process.pid}.flexr.rb")
    File.binwrite(path, source)
    path
  end

  it "labels runtime undefined states and malformed source" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a/) { push :missing }
    end

    expect { lexer_class.new("a").tokens }
      .to raise_error(Flexr::CompileError) { |error| expect(error.diagnostic.code).to eq("FLEXR-E003") }

    path = write_spec("syntax", "class Broken < Flexr::Lexer\n  rule(/a/) { emit :A }\n")
    expect { Flexr::Generator.new(path).generate }
      .to raise_error(Flexr::CompileError) { |error| expect(error.diagnostic.code).to eq("FLEXR-E010") }
  ensure
    FileUtils.rm_f(path) if path
  end

  it "reports a missing Prism dependency as FLEXR-E019" do
    reader = Flexr::Source::PrismReader.new("class Lexer < Flexr::Lexer; end")
    allow(reader).to receive(:require).with("prism").and_raise(LoadError, "missing prism")

    expect { reader.read }
      .to raise_error(Flexr::CompileError) { |error| expect(error.diagnostic.code).to eq("FLEXR-E019") }
  end

  it "emits exact warning codes for semantic and performance boundaries" do
    variable = Class.new(Flexr::Lexer) do
      rule(/a+/, followed_by: /b+/) { emit :A }
    end
    variable_codes = variable.compile!.diagnostics.map(&:code)
    expect(variable_codes).to include("FLEXR-W003", "FLEXR-W012")

    firstmatch = Class.new(Flexr::Lexer) do
      backend :firstmatch
      option :experimental
      rule(/a/) { emit :A }
      rule(/b/) { emit :B }
    end
    expect(firstmatch.compile!.diagnostics.map(&:code)).to include("FLEXR-W010")

    compiler = Flexr::Automaton::Compiler.new(Flexr::IR::Spec.new(
      class_name: "DiagnosticFixture", superclass: "Flexr::Lexer", backend: :table,
      token_kind: :array, encoding: Encoding::UTF_8, options: {}, declared_tokens: [],
      states: { initial: Flexr::IR::State.new(name: :initial, inclusive: true, id: 0) },
      rules: [], eof_rules: {}, verbatim: nil
    ))
    compiled = Flexr::Automaton::CompiledSpec.new(
      machines: {}, rules: [], states: [:initial],
      stats: { initial: { states: 2_001, classes: 501 } }, diagnostics: []
    )
    codes = compiler.send(:diagnostics_for, compiled, 0.501).map(&:code)
    expect(codes).to include("FLEXR-W011", "FLEXR-W016")
  end

  it "does not mistake parentheses inside character classes for captures" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/[()]/) { skip }
    end

    expect(lexer_class.compile!.diagnostics.map(&:code)).not_to include("FLEXR-W013")
  end

  it "finds captures after non-capturing groups" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/(?:prefix)(suffix)/) { skip }
    end

    expect(lexer_class.compile!.diagnostics.map(&:code)).to include("FLEXR-W013")
  end
end
