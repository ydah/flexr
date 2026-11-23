# frozen_string_literal: true

RSpec.describe "regexp line breaks" do
  it "agrees with Ruby on whole matches, including atomic CRLF" do
    patterns = [/\R/u, /\R\n/u, /\R{2}/u, /a\Rz/u, /[\RA]/u]
    pieces = ["\r", "\n", "\v", "\f", "\u0085", "\u2028", "\u2029", "a", "z", "R", "A"]
    inputs = [""] + (1..3).flat_map { |length| pieces.repeated_permutation(length).map(&:join) }

    patterns.each do |pattern|
      reference = Regexp.new("\\A(?:#{pattern.source})\\z", pattern.options)
      dfa = Flexr.compile_pattern(pattern)
      inputs.each do |input|
        expect(dfa.accept?(input)).to eq(reference.match?(input)), "#{pattern.inspect} on #{input.inspect}"
      end
    end
  end

  it "uses the binary line breaks for binary patterns" do
    pattern = /\R\n/n
    reference = Regexp.new("\\A(?:#{pattern.source})\\z", pattern.options)
    dfa = Flexr.compile_pattern(pattern, encoding: Encoding::BINARY)
    inputs = ["\r\n", "\r\n\n", "\f\n", "\x85\n", "\xff\n"].map(&:b)
    inputs.each do |input|
      expect(dfa.accept?(input)).to eq(reference.match?(input)), input.inspect
    end
  end

  it "retains the CRLF condition across a pattern product and concatenation" do
    cr = Flexr::Pattern.build(/\R/) & "\r"
    lf = Flexr::Pattern.build("\n")
    dfa = Flexr.compile_pattern(cr + lf)
    expect(dfa.accept?("\r\n")).to be(false)
  end

  it "checks a byte beyond the rule body at the end of a lexical candidate" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/\R/, followed_by: /\n/, emit: :BEFORE_LF)
      rule(/\R/, emit: :BREAK)
    end

    expect(lexer.new("\r\n").tokens).to eq([[:BREAK, "\r\n"]])
    expect(lexer.new(StringIO.new("\r\n\n"), chunk_size: 1).tokens).to eq([[:BEFORE_LF, "\r\n"], [:BREAK, "\n"]])
  end

  it "recognizes a rule that can win when an earlier rule fails its next-byte condition" do
    lexer = Class.new(Flexr::Lexer) do
      rule(pattern(/\R/) & "\r", emit: :LONE_CR)
      rule(/\r/, emit: :CR)
      rule(/\n/, skip: true)
    end

    expect(lexer.new("\r\n").tokens).to eq([[:CR, "\r"]])
    expect(lexer.compile!.diagnostics.map(&:code)).not_to include("FLEXR-W001")
  end

  it "keeps a rule shadowed if the next byte always completes a longer match" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/\R/, emit: :BREAK)
      rule(/\r/, emit: :CR)
    end

    expect(lexer.new("\r\n").tokens).to eq([[:BREAK, "\r\n"]])
    expect(lexer.compile!.diagnostics.map(&:code)).to include("FLEXR-W001")
  end

  it "checks whether a suffix can reject the longer match" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/\R$/, emit: :LINE_END)
      rule(/\r/, emit: :CR)
      rule(/[\nx]/, skip: true)
    end

    expect(lexer.new("\r\nx").tokens).to eq([[:CR, "\r"]])
    expect(lexer.compile!.diagnostics.map(&:code)).not_to include("FLEXR-W001")
  end

  it "checks next-byte conditions both at and beyond the beginning of a line" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/^\R/, emit: :FIRST_BREAK)
      rule(/\r/, emit: :CR)
      rule("x", skip: true)
    end

    expect(lexer.new("x\r").tokens).to eq([[:CR, "\r"]])
    expect(lexer.compile!.diagnostics.map(&:code)).not_to include("FLEXR-W001")
  end
end
