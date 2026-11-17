# frozen_string_literal: true

require "stringio"

RSpec.describe "regexp escape rewrites" do
  it "provides concrete examples and their limits for unsupported escapes" do
    {
      'a\Kb' => ['rule(/a/, followed_by: /b/) { begin_state :suffix }',
                  'state(:suffix) { rule(/b/) { begin_state :initial; emit :B } }', "in :initial", "unused state name"],
      '(a|b)\g<1>' => ['rule(/[ab]{2}/)', "non-recursive", "recursive calls need a parser or state stack"],
      '\X' => ['rule(/\r\n|[\x00-\x7f]/)', "standalone", "ASCII-only", "Unicode graphemes need separate segmentation"],
      '\cA' => ['rule(/\x01/)', "control-A", "other control characters need their own hexadecimal code"],
      '\C-A' => ['rule(/\x01/)', "control-A", "other control characters need their own hexadecimal code"],
      '\M-a' => ['rule(/\xE1/n)', "binary input", "other meta characters need their own byte value"]
    }.each do |source, expected|
      expect { Flexr::Regexp::Parser.new(source, encoding: Encoding::BINARY).parse }
        .to raise_error(Flexr::UnsupportedRegexpError) do |error|
          expect(error.diagnostic.code).to eq("FLEXR-E014")
          expect(error.diagnostic.help).to include(*expected, "keep the action")
        end
    end
  end

  it "inlines the called expression rather than repeating the captured text" do
    dfa = Flexr.compile_pattern(/[ab]{2}/)
    ["", "a", "aa", "ab", "ba", "bb", "ac", "aba"].each do |input|
      expect(dfa.accept?(input)).to eq(/\A(a|b)\g<1>\z/.match?(input))
    end
    expect(dfa.accept?("ab")).to be(true)
    expect(/\A(a|b)\1\z/.match?("ab")).to be(false)
  end

  it "preserves control and meta byte values with hexadecimal escapes" do
    { '\cA' => /\x01/n, '\C-A' => /\x01/n, '\M-a' => /\xE1/n }.each do |source, rewritten|
      original = Regexp.new(source, Regexp::NOENCODING)
      dfa = Flexr.compile_pattern(rewritten)
      (0..255).each do |byte|
        input = [byte].pack("C")
        expect(dfa.accept?(input)).to eq(original.match?(input)), "#{source} on byte #{byte}"
      end
    end
  end

  %i[table direct auto firstmatch].each do |backend|
    it "preserves standalone ASCII graphemes and CRLF with #{backend}" do
      lexer = Class.new(Flexr::Lexer) do
        backend backend
        option :experimental if backend == :firstmatch
        rule(/\r\n|[\x00-\x7f]/) { emit :GRAPHEME }
      end
      input = "#{(0..127).to_a.pack('C*')}\r\n\rx\n"
      expected = input.scan(/\X/).map { |text| [:GRAPHEME, text.bytes] }
      [input, StringIO.new(input)].each do |source|
        actual = lexer.new(source, chunk_size: 1).tokens.map { |type, text| [type, text.bytes] }
        expect(actual).to eq(expected)
      end
      expect(expected).to include([:GRAPHEME, [13, 10]])
    end

    it "preserves the match-reset suffix and its location with #{backend}" do
      lexer = Class.new(Flexr::Lexer) do
        backend backend
        option :experimental if backend == :firstmatch
        token_kind :struct
        rule(/a/, followed_by: /b/) { begin_state :suffix }
        state(:suffix) do
          rule(/b/) do
            begin_state :initial
            emit :B
          end
        end
        rule(/./m) { emit :OTHER }
      end

      ["", "a", "b", "ab", "ac", "aabac", "ababa", "\nab\nab"].each do |input|
        expected = []
        offset = 0
        while (match = /a\Kb/.match(input, offset))
          expected << [match[0], match.begin(0), match.end(0)]
          offset = match.end(0)
        end
        [input, StringIO.new(input)].each do |source|
          instance = lexer.new(source, chunk_size: 1)
          actual = instance.tokens.select { |token| token.type == :B }.map do |token|
            [token.value, token.location.byte_begin, token.location.byte_end]
          end
          expect(actual).to eq(expected)
          expect(instance.state).to eq(:initial)
        end
      end
      expect(lexer.new("aabac").tokens.map { |token| [token.type, token.value] })
        .to eq([[:OTHER, "a"], [:B, "b"], [:OTHER, "a"], [:OTHER, "c"]])
    end
  end
end
