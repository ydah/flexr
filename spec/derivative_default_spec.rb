# frozen_string_literal: true

require "flexr/automaton/derivative_compiler"

RSpec.describe "the default DFA compiler" do
  it "uses derivatives for runtime compilation and static generation" do
    expect(Flexr::Automaton::DerivativeCompiler).to receive(:new).twice.and_call_original

    lexer_class = Class.new(Flexr::Lexer) { rule("ab", emit: :WORD) }
    expect(lexer_class.new("ab").tokens).to eq([[:WORD, "ab"]])

    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.write(path, 'class DefaultLexer < Flexr::Lexer; rule("ab", emit: :WORD); end')
      expect(Flexr::Generator.new(path).generate).to include("install_compiled!")
    end
  end

  it "keeps the subset reference and derivative compiler in separate cache entries" do
    original_cache = Flexr.cache_dir
    Dir.mktmpdir do |directory|
      Flexr.cache_dir = directory
      %i[subset derivative].each do |construction|
        lexer_class = Class.new(Flexr::Lexer) { rule("ab", emit: :WORD) }
        Flexr::Automaton::Compiler.new(lexer_class.__flexr_spec, construction: construction).compile
      end

      expect(Dir.glob(File.join(directory, "*.dfa")).size).to eq(2)
      expect(Flexr::Automaton::DerivativeCompiler).not_to receive(:new)
      lexer_class = Class.new(Flexr::Lexer) { rule("ab", emit: :WORD) }
      expect(lexer_class.new("ab").tokens).to eq([[:WORD, "ab"]])
    end
  ensure
    Flexr.cache_dir = original_cache
  end
end
