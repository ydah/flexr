# frozen_string_literal: true

RSpec.describe "regexp lookahead" do
  it "agrees with whole Ruby matches when assertions overlap the match or each other" do
    patterns = [
      /a(?=bc)bc/, /a(?!bc)b[cd]/, /a(?=b(?!c))b[cd]/, /(?=ab)a(?=b)b/,
      /(?:(?=a)a|b){2}/, /a(?=b)|b(?!a)/, /a(?=b*)/, /a(?!b*)/, /a(?=\R)\r\n/
    ]
    inputs = (1..4).flat_map { |size| %W[a b c d \r \n].repeated_permutation(size).map(&:join) }
    patterns.each do |pattern|
      native = Regexp.new("\\A(?:#{pattern.source})\\z", pattern.options)
      compiled = Flexr.compile_pattern(pattern)
      inputs.each do |input|
        expect(compiled.accept?(input)).to eq(native.match?(input)), "#{pattern.inspect} on #{input.inspect}"
      end
    end
  end

  it "uses the suffix beyond the token without consuming it" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/-(?!\d)/, emit: :MINUS)
      rule(/-\d+/, emit: :SIGNED)
      rule(/a(?=bc)b/, emit: :PREFIX)
      rule(/./, emit: :OTHER)
    end

    input = "-x-12abcabd-"
    expected = [[:MINUS, "-"], [:OTHER, "x"], [:SIGNED, "-12"], [:PREFIX, "ab"], [:OTHER, "c"],
                [:OTHER, "a"], [:OTHER, "b"], [:OTHER, "d"], [:MINUS, "-"]]
    expect(lexer.new(StringIO.new(input), chunk_size: 1).tokens).to eq(expected)
  end


  it "stops upto at the first terminator whose lookahead succeeds" do
    lexer = Class.new(Flexr::Lexer) do
      rule(upto(/b(?=c)/), emit: :UPTO)
      rule(/./, emit: :OTHER)
    end

    expect(lexer.new("xbdbcd").next_token).to eq([:UPTO, "xbdb"])
  end

  it "subtracts only those matches whose lookahead succeeds" do
    lexer = Class.new(Flexr::Lexer) do
      rule(pattern("a") - /a(?=b)/, emit: :A)
      rule(/./, emit: :OTHER)
    end

    expect(lexer.new("ab").next_token).to eq([:OTHER, "a"])
    expect(lexer.new("ac").next_token).to eq([:A, "a"])
  end

  it "rejects a zero-width match even when it needs nonempty input" do
    lexer = Class.new(Flexr::Lexer) { rule(/a|(?=b)/, emit: :TOKEN) }

    expect { lexer.compile! }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E005")
    end
  end

  it "limits the bytes read to resolve a lookahead independently of the token length" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a(?=bc)/, emit: :TOKEN)
      rule(/./, emit: :OTHER)
    end

    expect { lexer.new(StringIO.new("abc"), chunk_size: 1, max_lookahead_size: 1).next_token }
      .to raise_error(Flexr::Runtime::LookaheadTooLargeError)
    expect(lexer.new(StringIO.new("abc"), chunk_size: 1, max_lookahead_size: 2).next_token).to eq([:TOKEN, "a"])
  end



  it "charges the limit for a direct LF assertion" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a(?=\n)/, emit: :A)
      rule(/./, emit: :OTHER)
    end

    expect { lexer.new("a\n", max_lookahead_size: 0).next_token }
      .to raise_error(Flexr::Runtime::LookaheadTooLargeError)
    expect(lexer.new("a\n", max_lookahead_size: 1).next_token).to eq([:A, "a"])
  end

  it "charges the suffix that establishes a grapheme boundary across backends" do
    %i[table direct firstmatch].each do |backend_name|
      lexer = Class.new(Flexr::Lexer) do
        backend backend_name
        rule(/\X/, emit: :GRAPHEME)
      end

      expect { lexer.new(StringIO.new("a🇯🇵"), chunk_size: 1, max_lookahead_size: 1).next_token }
        .to raise_error(Flexr::Runtime::LookaheadTooLargeError)
      expect(lexer.new(StringIO.new("a🇯🇵"), chunk_size: 1, max_lookahead_size: 4).next_token).to eq([:GRAPHEME, "a"])
    end
  end

  it "charges nested assertions against the full trailing-context limit" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a/, followed_by: /b(?=cd)/, emit: :A)
      rule(/./, emit: :OTHER)
    end

    expect { lexer.new(StringIO.new("abcd"), chunk_size: 1, max_lookahead_size: 2).next_token }
      .to raise_error(Flexr::Runtime::LookaheadTooLargeError)
    expect(lexer.new(StringIO.new("abcd"), chunk_size: 1, max_lookahead_size: 3).next_token).to eq([:A, "a"])
  end


  it "shows a concrete suffix when a longer rule always wins over a lookahead rule" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/ab/, emit: :AB)
      rule(/a(?=b)/, emit: :A)
      rule(/./, emit: :OTHER)
    end

    warning = lexer.compile!.diagnostics.find { |diagnostic| diagnostic.code == "FLEXR-W001" }
    expect(warning.note).to include('example: "ab"', 'longest')
    expect(lexer.new("ab").next_token).to eq([:AB, "ab"])
  end

  it "does not warn when a later rule can win with a different suffix" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a(?=bc)/, emit: :WITH_C)
      rule(/a(?=b)/, emit: :WITHOUT_C)
      rule(/./, emit: :OTHER)
    end

    expect(lexer.compile!.diagnostics.map(&:code)).not_to include("FLEXR-W001")
    expect(lexer.new("ab").next_token).to eq([:WITHOUT_C, "a"])
  end

  it "keeps firstmatch rule order when a negative assertion needs the next chunk" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a(?!bc)/, emit: :A)
      rule(/(?=ab)ab/, emit: :AB)
      rule(/./, emit: :OTHER)
    end

    expect(lexer.new(StringIO.new("abc"), chunk_size: 2).tokens).to eq([[:AB, "ab"], [:OTHER, "c"]])
  end

  it "does not probe a later firstmatch alternative after a branch succeeds" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a|a(?=b*z)/, emit: :A)
    end

    expect(lexer.new(StringIO.new("abbbb"), chunk_size: 1, max_lookahead_size: 0).next_token).to eq([:A, "a"])
  end



  it "applies the firstmatch token size limit to the selected match" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a+b(?=c)|a/, emit: :TOKEN)
    end

    expect(lexer.new("aaaaax", max_token_size: 1).next_token).to eq([:TOKEN, "a"])
    expect { lexer.new("aabc", max_token_size: 1).next_token }.to raise_error(Flexr::Runtime::TokenTooLargeError)
  end

  it "resolves a capture-free nullable assertion without reading unrelated bytes" do
    %i[firstmatch table].each do |mode|
      lexer = Class.new(Flexr::Lexer) do
        backend mode
        rule(/(?<text>a)(?=b*)/) { emit :A, captures[:text] }
      end

      expect(lexer.new(StringIO.new("abbbb"), chunk_size: 1, max_lookahead_size: 0).next_token)
        .to eq([:A, "a"])
    end
  end

  it "replays the Ruby capture branch that is valid in the input after the selected token" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/(?<left>a)(?=(?<tail>bc))|(?<right>a)/) { emit :A, captures }
      rule(/./, emit: :OTHER)
    end

    via_stream = ->(input) { lexer.new(StringIO.new(input), chunk_size: 1).next_token }
    expect(via_stream.call("abc")).to eq([:A, {left: "a", tail: "bc", right: nil}])
    expect(via_stream.call("abd")).to eq([:A, {left: nil, tail: nil, right: "a"}])
  end

  it "replays captures at the exact byte range chosen by longest match" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/(?<short>é)(?=日)|(?<long>é日)(?=x)/) { emit :TOKEN, captures }
      rule(/./, emit: :OTHER)
    end

    input = StringIO.new("é日x")
    expect(lexer.new(input, chunk_size: 1).tokens)
      .to eq([[:TOKEN, {short: nil, long: "é日"}], [:OTHER, "x"]])
  end
end
