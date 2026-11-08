# frozen_string_literal: true

RSpec.describe "compiler diagnostic patterns" do
  it "identifies a multi-pattern rule and each rule shadowing it" do
    lexer = Class.new(Flexr::Lexer) do
      rule("a", skip: true)
      rule("b", skip: true)
      rule(%w[a b], skip: true)
    end

    warning = lexer.compile!.diagnostics.find { |item| item.code == "FLEXR-W001" }

    expect(warning.message).to eq('rule ["a", "b"] is unreachable (shadowed by rule "a", rule "b")')
    expect(warning.location).to be_nil
  end

  it "preserves regexp options and the other patterns in an empty-match error" do
    lexer = Class.new(Flexr::Lexer) { rule(["x", /a*/i], skip: true) }

    expect { lexer.compile! }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E005")
      expect(error.message).to eq('rule ["x", /a*/i] can match an empty string')
      expect(error.diagnostic.message).to eq(error.message)
    end
  end

  it "escapes literal control characters and includes normalized string trailing context" do
    lexer = Class.new(Flexr::Lexer) { rule("a\n", followed_by: "\t", skip: true) }

    warning = lexer.compile!.diagnostics.find { |item| item.code == "FLEXR-W012" }

    expect(warning.message)
      .to eq('rule "a\n", followed_by: /\t/ cannot use region acceleration with trailing context')
  end

  it "lists only the patterns in the state that exceeds the DFA limit" do
    lexer = Class.new(Flexr::Lexer) do
      rule("z", skip: true)
      state :word do
        rule(/ab/, skip: true)
        rule(/ac/i, skip: true)
      end
    end
    lexer.__flexr_config.options[:max_dfa_states] = 2

    expect { lexer.compile! }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E006")
      expect(error.message).to eq("DFA state limit exceeded while compiling rule /ab/, rule /ac/i")
    end
  end
end
