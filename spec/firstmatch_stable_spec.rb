# frozen_string_literal: true

require "stringio"

RSpec.describe "stable firstmatch backend" do
  it "selects the first matching rule without an experimental opt-in" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a/) { emit :A }
      rule(/ab/) { emit :AB }
      rule(/b/) { emit :B }
    end
    ["ab", StringIO.new("ab")].each do |input|
      expect(lexer.new(input, chunk_size: 1).tokens).to eq([[:A, "a"], [:B, "b"]])
    end
    expect(lexer.compile!.diagnostics.map(&:code)).to include("FLEXR-W010")
  end

  it "keeps generated firstmatch behavior without an experimental option" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      File.write(path, <<~RUBY)
        class StableFirstmatchFixture < Flexr::Lexer
          backend :firstmatch
          rule(/a|ab/) { emit :A }
          rule(/b/) { emit :B }
        end
      RUBY
      Flexr::Generator.new(path, output: output).generate
      load output
      expect(StableFirstmatchFixture.new("ab").tokens).to eq([[:A, "a"], [:B, "b"]])
    ensure
      Object.send(:remove_const, :StableFirstmatchFixture) if Object.const_defined?(:StableFirstmatchFixture, false)
    end
  end
end
