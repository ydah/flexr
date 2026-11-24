# frozen_string_literal: true

require "stringio"

RSpec.describe "tagged capture scanning" do
  it "keeps the ranges of the selected body after probing a longer match" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/(?<head>a)(?<word>a+)/) do
        raise "named captures were replayed" unless @capture_match.capture.respond_to?(:byteoffset)

        emit :TAGGED, captures
      end
      rule(/a+b+c/, emit: :LONG)
      rule(/b+!/, emit: :REST)
    end
    input = StringIO.new("aaabbb!")

    expect(lexer.new(input, retain_input: false, chunk_size: 1).tokens).to eq(
      [[:TAGGED, {head: "a", word: "aa"}], [:REST, "bbb!"]]
    )
  end

  it "replays the selected body if a rule action changes the mutable input" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/(?<left>ab|a)(?<right>[bc]?)/) do
        input.setbyte(1, "c".ord)
        emit :CAPTURE, captures
      end
    end

    expect(lexer.new(+"ab").next_token).to eq([:CAPTURE, {left: "a", right: "c"}])
  end

  it "replays the selected body if reading a stream exposes mutable input during scanning" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/(?<left>ab|a)(?<right>[bc]?)/) { emit :CAPTURE, captures }
    end
    chunks = %w[a b !]
    stream = Object.new
    scanner = nil
    stream.define_singleton_method(:read) do |_size|
      scanner.input.setbyte(1, "c".ord) if chunks.one?
      chunks.shift
    end
    scanner = lexer.new(stream, chunk_size: 1)

    expect(scanner.next_token).to eq([:CAPTURE, {left: "a", right: "c"}])
  end

  it "uses replay and reports an informational diagnostic when tag registers exceed the limit" do
    groups = (1..64).map { |index| "(?<group_#{index}>a)" }
    pattern = Regexp.new(groups.push("(?<last>a)").join)
    lexer = Class.new(Flexr::Lexer) do
      rule(pattern) { emit :CAPTURE, captures.fetch(:last) }
    end

    expect(lexer.compile!.diagnostics).to include(have_attributes(
      code: "FLEXR-I005", severity: :info, note: "tagged DFA register limit exceeded"
    ))
    expect(lexer.new("a" * 65).next_token).to eq([:CAPTURE, "a"])
  end
end
