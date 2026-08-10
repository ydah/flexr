# frozen_string_literal: true

require "spec_helper"

require_relative "../lib/flexr/regexp/tokenizer"
require_relative "../tools/regexp_tokenizer_reference"

RSpec.describe FlexrVerification::RegexpTokenizerReference do
  describe ".tokens" do
    it "matches the binary tokenizer contract at UTF-8 byte boundaries" do
      input = "あa"

      expect(described_class.tokens(input)).to eq([
        [:LITERAL, input.byteslice(0, 1)],
        [:LITERAL, input.byteslice(1, 1)],
        [:LITERAL, input.byteslice(2, 1)],
        [:LITERAL, input.byteslice(3, 1)]
      ])
      expect(Flexr::Regexp::SourceLexer.new(input).tokens).to eq(described_class.tokens(input))
    end

    it "treats invalid UTF-8 and binary input as the same bytes" do
      binary = "\xffa".b
      invalid_utf8 = binary.dup.force_encoding(Encoding::UTF_8)
      expected_binary = [[:LITERAL, binary.byteslice(0, 1)], [:LITERAL, binary.byteslice(1, 1)]]
      expected_invalid = [[:LITERAL, invalid_utf8.byteslice(0, 1)],
                          [:LITERAL, invalid_utf8.byteslice(1, 1)]]

      expect(described_class.tokens(binary)).to eq(expected_binary)
      expect(described_class.tokens(invalid_utf8)).to eq(expected_invalid)
      expect(described_class.tokens(invalid_utf8).map { |token| token.last.bytes })
        .to eq(described_class.tokens(binary).map { |token| token.last.bytes })
      expect(Flexr::Regexp::SourceLexer.new(invalid_utf8).tokens).to eq(expected_invalid)
    end

    it "raises a structured error for an unmatched input byte" do
      expect { described_class.tokens("a\\") }
        .to raise_error(described_class::UnmatchedInputError) do |error|
          expect(error.offset).to eq(1)
          expect(error.byte).to eq("\\".ord)
          expect(error.message).to include("offset 1", "0x5c")
        end
    end

    it "does not accept malformed delimiter boundaries" do
      ["[", "]", "{"].each do |input|
        expect { described_class.tokens(input) }
          .to raise_error(described_class::UnmatchedInputError) do |error|
            expect(error.offset).to eq(0)
            expect(error.byte).to eq(input.ord)
          end
      end
    end
  end
end
