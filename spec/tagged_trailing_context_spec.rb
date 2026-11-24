# frozen_string_literal: true

require "stringio"

RSpec.describe "tagged trailing context" do
  it "shares suffix transitions across competing body endpoints" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a+/, followed_by: /a+/, emit: :BODY)
    end
    input = "a" * 256
    scanner = lexer.new(input)
    transitions = 0
    trace = TracePoint.new(:call) do |event|
      transitions += 1 if event.method_id == :transition && event.self.is_a?(Flexr::Automaton::DFA)
    end

    token = trace.enable { scanner.next_token }

    expect(token).to eq([:BODY, input[0...-1]])
    expect(transitions).to be <= input.bytesize * 4
  end

  it "ranks the longer body when a shorter regexp alternative also fills the trailer" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/(?<part>a|aa)/, followed_by: /a+/) { emit :BODY, captures.fetch(:part) }
      rule("a", emit: :REST)
    end

    expect(lexer.new("aaa").tokens).to eq([[:BODY, "aa"], [:REST, "a"]])
  end

  it "uses the first pattern's capture values at the selected split" do
    lexer = Class.new(Flexr::Lexer) do
      rule([/(?<head>a)(?<tail>a?)/, /(?<part>a|aa)/], followed_by: /a+/) do
        emit :BODY, [text, captures]
      end
      rule("a", emit: :REST)
    end
    expected = [[:BODY, ["aa", {head: "a", tail: "a"}]], [:REST, "a"]]

    expect(lexer.new("aaa").tokens).to eq(expected)
    expect(lexer.new("aaa", max_steps: 100).tokens).to eq(expected)
    expect(lexer.new(StringIO.new("aaa"), chunk_size: 1, retain_input: false).tokens).to eq(expected)
  end

  it "ranks the total length and applies parser expectations at each body endpoint" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a+/, followed_by: /a+/, emit: :IDENT)
      rule("aaa", emit: :LONG, priority: 1)
      keywords({ "aa" => :KEY }, among: :IDENT)
    end

    expect(lexer.new("aaa").next_token).to eq([:LONG, "aaa"])
    expect(lexer.new("aaa").next_token(expect: [:KEY])).to eq([:KEY, "aa"])
    expect(lexer.new("aaa").next_token(expect: [:IDENT])).to eq([:IDENT, "a"])
  end

  it "keeps a line-start split if a later split reaches the same trailer state" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/x\n?b?/, followed_by: /^b*é+\z/, emit: :BODY)
      rule(/bé+/, emit: :REST)
    end

    expect(lexer.new("x\nbéé").tokens).to eq([[:BODY, "x\n"], [:REST, "béé"]])
  end

  it "keeps variable pattern trailers at UTF-8 boundaries" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/é+/, followed_by: pattern(/é+/) + pattern("!"), emit: :BODY)
      rule(/é!/, emit: :REST)
      rule("x", followed_by: /\xC3/n, emit: :PARTIAL)
      rule("x", emit: :PREFIX)
    end

    expect(lexer.new("xééé!", retain_input: false).tokens).to eq(
      [[:PREFIX, "x"], [:BODY, "éé"], [:REST, "é!"]]
    )
  end

  it "honors a tight lookahead limit even at an earlier losing split" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a+/, followed_by: /a+/, emit: :BODY)
      rule("aaa", emit: :LONG, priority: 1)
    end

    expect { lexer.new("aaa", max_lookahead_size: 1).next_token }
      .to raise_error(Flexr::Runtime::LookaheadTooLargeError) { |error| expect(error.rule).to eq(0) }
    expect(lexer.new("aaa", max_lookahead_size: 1).next_token(expect: [:LONG])).to eq([:LONG, "aaa"])
  end

  it "preserves the order of reads from strings with custom byte access" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a+/, followed_by: /a+/, emit: :BODY)
      rule(/[ab]/, emit: :REST)
    end
    reader = Module.new do
      def getbyte(index)
        @reads = @reads.to_i + 1
        setbyte(1, "b".ord) if @reads == 7
        super
      end
    end
    subclass = Class.new(String) { include reader }

    [subclass.new("aaaa"), (+"aaaa").extend(reader)].each do |input|
      expect(lexer.new(input, freeze_input: false).next_token).to eq([:BODY, "a"])
    end
  end
end
