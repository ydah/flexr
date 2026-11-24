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

  it "keeps an earlier longer alternative eligible across chunk boundaries" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/abc|a/, emit: :WORD)
      rule(/./m, emit: :OTHER)
    end

    expected = [[:WORD, "abc"], [:WORD, "a"], [:OTHER, "b"]]
    expect(lexer.new("abcab").tokens).to eq(expected)
    [1, 2, 3].each do |chunk_size|
      input = StringIO.new("abcab")
      expect(lexer.new(input, chunk_size: chunk_size, retain_input: false).tokens).to eq(expected)
    end
  end

  it "returns a higher priority short branch without reading the rest of a possible longer branch" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a|a+z/, emit: :WORD)
    end

    input = StringIO.new("a" * 100)
    expect(lexer.new(input, chunk_size: 1, max_buffer_size: 2).next_token).to eq([:WORD, "a"])
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
