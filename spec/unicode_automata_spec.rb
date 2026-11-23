# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "vendored UTF-8 property automata" do
  it "compiles a Unicode identifier with several property fragments" do
    expect(Flexr::Unicode::Property).not_to receive(:ranges)
    dfa = Flexr.compile_pattern(/\p{L}[\p{L}\p{N}_]*/)

    %w[日本語23 Île_7 α٢].each { |identifier| expect(dfa).to be_accept(identifier) }
    ["", "7abc", "a!", "a\xed\xa0\x80".b].each { |text| expect(dfa).not_to be_accept(text) }
  end

  it "uses the same fragments for aliases, case folding, and negated properties" do
    expect(Flexr::Unicode::Property).not_to receive(:ranges)

    expect(Flexr.compile_pattern(/\p{Letter}/)).to be_accept("字")
    expect(Flexr.compile_pattern(/\p{Lu}/i)).to be_accept("é")
    expect(Flexr.compile_pattern(/\P{Nd}/)).not_to be_accept("٢")
    expect(Flexr.compile_pattern(/\P{Nd}/)).to be_accept("é")
    expect(Flexr.compile_pattern(/[[:alpha:]]/)).to be_accept("字")
  end

  it "complements a union at UTF-8 scalar boundaries" do
    expect(Flexr::Unicode::Property).not_to receive(:ranges)
    dfa = Flexr.compile_pattern(/[^\p{L}\p{Nd}-]/)

    ["!", "😀"].each { |character| expect(dfa).to be_accept(character) }
    ["字", "٢", "-", "", "\xed\xa0\x80".b, "\xf4\x90\x80\x80".b].each do |text|
      expect(dfa).not_to be_accept(text)
    end
  end

  it "excludes invalid UTF-8 from broad scalar ranges" do
    [/\P{ASCII}/, /[\u{80}-\u{10ffff}]/].each do |pattern|
      dfa = Flexr.compile_pattern(pattern)
      ["\u{800}", "\u{d7ff}", "\u{10000}", "\u{10ffff}"].each do |scalar|
        expect(dfa).to be_accept(scalar)
      end
      ["\xe0\x80\x80", "\xed\xa0\x80", "\xf0\x80\x80\x80", "\xf4\x90\x80\x80"].each do |bytes|
        expect(dfa).not_to be_accept(bytes.b)
      end
    end
  end

  it "keeps valid Unicode classes compilable under tight DFA state limits" do
    bounded = Flexr.compile_pattern(/[^\p{Any}a]|b/, options: { max_dfa_states: 2 })
    expect(bounded).to be_accept("b")
    expect(bounded).not_to be_accept("a")

    union = Flexr.compile_pattern(/[\p{Any}\p{L}]/, options: { max_dfa_states: 16 })
    expect(union).to be_accept("😀")
    expect(union).not_to be_accept("ab")

    bounded_union = Flexr.compile_pattern(/[\p{L}\P{L}]/, options: { max_dfa_states: 32 })
    expect(bounded_union).to be_accept("😀")
    expect(bounded_union).not_to be_accept("ab")
  end

  it "runs standalone output without the vendored automata file" do
    Dir.mktmpdir("flexr-unicode-standalone") do |directory|
      spec = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      File.write(spec, <<~'RUBY')
        class PropertyLexer < Flexr::Lexer
          rule(/\p{L}[\p{L}\p{N}_]*/, emit: :WORD)
        end
      RUBY
      Flexr::Generator.new(spec, output: output, options: { standalone: true }).generate
      program = <<~RUBY
        load ARGV.fetch(0)
        abort "wrong tokens" unless PropertyLexer.new("日本語23").tokens == [[:WORD, "日本語23"]]
      RUBY
      _, stderr, status = Open3.capture3({ "RUBYOPT" => nil, "RUBYLIB" => nil }, RbConfig.ruby, "--disable-gems",
                                        "-e", program, output)
      expect(status).to be_success, stderr
    end
  end
end
