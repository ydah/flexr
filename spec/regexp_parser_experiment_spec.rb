# frozen_string_literal: true

require_relative "../benchmark/regexp_parser_scanner"

RSpec.describe RegexpParserParity::Scanner do
  it "records character positions across absence groups and nested character sets" do
    expect(described_class.scan("😀(?~[[ä]&&[^b]])", nil)).to eq([
      [:literal, :literal, "😀", 0, 1], [:group, :absence, "(?~", 1, 4],
      [:set, :open, "[", 4, 5], [:set, :open, "[", 5, 6],
      [:literal, :literal, "ä", 6, 7], [:set, :close, "]", 7, 8],
      [:set, :intersection, "&&", 8, 10], [:set, :open, "[", 10, 11],
      [:set, :negate, "^", 11, 12], [:literal, :literal, "b", 12, 13],
      [:set, :close, "]", 13, 14], [:set, :close, "]", 14, 15], [:group, :close, ")", 15, 16]
    ])
  end

  it "stops group comments at their first close and uses captures for scanner token names" do
    input = "(?#😀)[[:^digit:]]++"
    expect(described_class.scan(input, nil)).to eq([
      [:group, :comment, "(?#😀)", 0, 5], [:set, :open, "[", 5, 6],
      [:nonposixclass, :digit, "[:^digit:]", 6, 16], [:set, :close, "]", 16, 17],
      [:quantifier, :one_or_more_possessive, "++", 17, 19]
    ])
  end

  it "rejects unknown POSIX classes" do
    expect do
      described_class.scan("[[:^:]]", nil)
    end.to raise_error(RegexpParserParity::Unsupported, "unknown POSIX classes")
  end
end
