# frozen_string_literal: true

RSpec.describe "firstmatch rule examples" do
  def lexer_class(&rules)
    Class.new(Flexr::Lexer) do
      backend :firstmatch
      option :experimental
      class_eval(&rules)
    end
  end

  def warning(lexer)
    lexer.compile!.diagnostics.find { |item| item.code == "FLEXR-W001" }
  end

  it "identifies an earlier prefix instead of the same-length DFA winner" do
    lexer = lexer_class do
      rule(/a/, emit: :PREFIX)
      rule(/ab/, emit: :WORD)
      rule(/ab/, emit: :HIDDEN)
    end

    diagnostic = warning(lexer)
    expect(diagnostic.message).to eq("rule /ab/ is unreachable")
    expect(diagnostic.note).to eq('example: "ab" selects rule /a/ (first match wins, matched 1 byte)')
    expect(lexer.new("ab").next_token).to eq([:PREFIX, "a"])
  end

  it "respects regexp alternative order and options" do
    lexer = lexer_class do
      rule(/a|ab/i, emit: :PREFIX)
      rule(/ab/i, emit: :HIDDEN)
    end

    expect(warning(lexer).note).to eq('example: "AB" selects rule /a|ab/i (first match wins, matched 1 byte)')
    expect(lexer.new("AB").next_token).to eq([:PREFIX, "A"])
  end

  it "chooses the longest matching pattern within the first rule" do
    lexer = lexer_class do
      rule(%w[a ab], emit: :WORD)
      rule("ab", emit: :HIDDEN)
    end

    expect(warning(lexer).note)
      .to eq('example: "ab" selects rule ["a", "ab"] (first match wins, matched 2 bytes)')
    expect(lexer.new("ab").tokens).to eq([[:WORD, "ab"]])
  end

  it "rejects earlier prefixes that require the end of a line" do
    lexer = lexer_class do
      rule(/^a$/, emit: :LINE)
      rule(/ab/, emit: :WORD)
      rule(/ab/, emit: :HIDDEN)
    end

    expect(warning(lexer).note).to eq('example: "ab" selects rule /ab/ (first match wins, matched 2 bytes)')
    expect(lexer.new("ab").tokens).to eq([[:WORD, "ab"]])
  end

  it "applies end-anchor checks after reference regexp alternative selection" do
    lexer = lexer_class do
      rule(/(?:\p{L}|\p{L}{2})$/, emit: :LETTER)
      rule(/ab/, emit: :WORD)
      rule(/ab/, emit: :HIDDEN)
    end

    expect(warning(lexer).note).to eq('example: "ab" selects rule /ab/ (first match wins, matched 2 bytes)')
    expect(lexer.compile!.diagnostics.count { |item| item.code == "FLEXR-W001" }).to eq(1)
    expect(lexer.new("ab").tokens).to eq([[:WORD, "ab"]])
  end

  it "omits a warning when the rule can be selected in another lexical state" do
    lexer = lexer_class do
      rule(/ab/, emit: :INITIAL)
      state :word do
        rule(/(?:\p{L}|\p{L}{2})$/, emit: :LETTER)
      end
      all_states { rule(/ab/, emit: :TARGET) }
    end

    expect(warning(lexer)).to be_nil
    expect(lexer.new("ab").tokens).to eq([[:INITIAL, "ab"]])
    scanner = lexer.new("ab")
    scanner.begin_state(:word)
    expect(scanner.tokens).to eq([[:TARGET, "ab"]])
  end

  it "uses the Unicode matcher and reports the matched length in bytes" do
    lexer = lexer_class do
      option :unicode
      rule(/\w/, emit: :WORD)
      rule(/é/, emit: :HIDDEN)
    end

    expect(warning(lexer).note).to eq('example: "é" selects rule /\w/ (first match wins, matched 2 bytes)')
    expect(lexer.new("é").tokens).to eq([[:WORD, "é"]])
  end

  it "does not include rules from other lexical states" do
    lexer = lexer_class do
      rule(/a/, emit: :PREFIX)
      state :word do
        rule(/ab/, emit: :WORD)
        rule(/ab/, emit: :HIDDEN)
      end
    end

    expect(warning(lexer).note)
      .to eq('example: "ab" selects rule /ab/ in state :word (first match wins, matched 2 bytes)')
    scanner = lexer.new("ab")
    scanner.begin_state(:word)
    expect(scanner.tokens).to eq([[:WORD, "ab"]])
  end

  it "reports an empty prefix without executing actions during compilation" do
    executed = []
    lexer = lexer_class do
      option :allow_empty_match
      rule(//) do
        executed << :empty
        emit :EMPTY
      end
      rule(/a/, emit: :A)
      rule(/a/, emit: :HIDDEN)
    end

    expect(warning(lexer).note).to eq('example: "a" selects rule // (first match wins, matched 0 bytes)')
    expect(executed).to be_empty
    expect(lexer.new("a").tokens).to eq([[:EMPTY, ""]])
    expect(executed).to eq([:empty])
  end

  it "handles binary input without requiring UTF-8 boundaries" do
    lexer = lexer_class do
      encoding Encoding::BINARY
      rule(/\xFF/n, emit: :BYTE)
      rule(/\xFF/n, emit: :HIDDEN)
    end

    expect(warning(lexer).note).to include('example: "\xFF"', "first match wins, matched 1 byte")
    expect(lexer.new("\xff".b).tokens).to eq([[:BYTE, "\xff".b]])
  end

  it "omits examples that fail native regexp encoding compatibility" do
    lexer = lexer_class do
      rule(/\xC3/n, emit: :PREFIX)
      rule(/é/, emit: :WORD)
      rule(/é/, emit: :HIDDEN)
    end

    expect(warning(lexer).note).to be_nil
  end
end
