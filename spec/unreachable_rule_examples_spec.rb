# frozen_string_literal: true

RSpec.describe "unreachable rule examples" do
  def warnings(lexer)
    lexer.compile!.diagnostics.select { |item| item.code == "FLEXR-W001" }
  end

  %i[table direct auto].each do |backend|
    it "shows the keyword consumed by an earlier rule with backend #{backend}" do
      lexer = Class.new(Flexr::Lexer) do
        backend backend
        rule(/[a-z]+/, emit: :WORD)
        rule(/if/, emit: :IF)
      end

      expect(warnings(lexer).first.note)
        .to eq('example: "if" selects rule /[a-z]+/ (same length, earlier rule wins)')
      expect(lexer.new("if").tokens).to eq([[:WORD, "if"]])
    end
  end

  it "finds the shortest input through loops and reports the actual winning rule" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a+/, emit: :A)
      rule("b", emit: :B)
      rule(/a{6,8}/, emit: :HIDDEN_A)
      rule(%w[aaaaaa b], emit: :HIDDEN_B)
    end

    expect(warnings(lexer).map(&:note)).to eq([
      'example: "aaaaaa" selects rule /a+/ (same length, earlier rule wins)',
      'example: "b" selects rule "b" (same length, earlier rule wins)'
    ])
    expect(lexer.new("aaaaaab").tokens).to eq([[:A, "aaaaaa"], [:B, "b"]])
  end

  it "identifies the lexical state needed to reproduce the example" do
    lexer = Class.new(Flexr::Lexer) do
      state :word do
        rule(/[a-z]+/, emit: :WORD)
        rule(/if/, emit: :IF)
      end
    end

    expect(warnings(lexer).first.note)
      .to eq('example: "if" selects rule /[a-z]+/ in state :word (same length, earlier rule wins)')
    scanner = lexer.new("if")
    scanner.begin_state(:word)
    expect(scanner.tokens).to eq([[:WORD, "if"]])
  end

  it "keeps valid UTF-8 examples readable" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/.+/, emit: :WORD)
      rule(/é/, emit: :HIDDEN)
    end

    expect(warnings(lexer).first.note)
      .to eq('example: "é" selects rule /.+/ (same length, earlier rule wins)')
    expect(lexer.new("é").tokens).to eq([[:WORD, "é"]])
  end

  it "escapes binary bytes and keeps the diagnostic JSON valid" do
    lexer = Class.new(Flexr::Lexer) do
      encoding Encoding::BINARY
      rule(/\xFF/n, emit: :BYTE)
      rule(/\xFF/n, emit: :HIDDEN)
    end

    warning = warnings(lexer).first
    expect(warning.note).to include('example: "\xFF"', "same length, earlier rule wins")
    expect(JSON.parse(JSON.generate(warning.to_h)).fetch("note")).to eq(warning.note)
    expect(lexer.new("\xff".b).tokens).to eq([[:BYTE, "\xff".b]])
  end

  it "escapes newlines in examples and permits anchors at the input boundaries" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/^\n$/, emit: :NEWLINE)
      rule("\n", emit: :HIDDEN)
    end

    expect(warnings(lexer).first.note)
      .to eq('example: "\n" selects rule /^\n$/ (same length, earlier rule wins)')
    expect(lexer.new("\n").tokens).to eq([[:NEWLINE, "\n"]])
  end

  it "finds a nonempty example when the DFA start state is accepting and loops" do
    lexer = Class.new(Flexr::Lexer) do
      option :allow_empty_match
      rule(/a*/, emit: :A)
      rule(/a*/, emit: :HIDDEN)
    end

    expect(warnings(lexer).first.note)
      .to eq('example: "a" selects rule /a*/ (same length, earlier rule wins)')
    expect(lexer.new("a").tokens).to eq([[:A, "a"]])
  end

  it "omits an example when only an empty input reaches the accepting state" do
    lexer = Class.new(Flexr::Lexer) do
      option :allow_empty_match
      rule(//, skip: true)
      rule(//, skip: true)
    end

    expect(warnings(lexer).first.note).to be_nil
  end

  it "omits an example whose bytes are invalid for the input encoding" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/\xFF/n, skip: true)
      rule(/\xFF/n, skip: true)
    end

    expect(warnings(lexer).first.note).to be_nil
  end

  it "omits unverified examples for trailing context" do
    trailing = Class.new(Flexr::Lexer) do
      rule(/a/, followed_by: "b", emit: :CONTEXT)
      rule(/a/, emit: :PLAIN)
    end
    expect(warnings(trailing).first.note).to be_nil
    expect(trailing.new("a").tokens).to eq([[:PLAIN, "a"]])
  end
end
