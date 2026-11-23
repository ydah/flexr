# frozen_string_literal: true

RSpec.describe "regexp right anchors" do
  it "agrees with Ruby on whole matches including internal line ends" do
    patterns = [/a\z/, /a\Z\n/, /a\r\Z\n/, /a$\nb/, /a(?=b$)b\n/, /a(?:\z|\Z\n)/, /a(?:$\n|b)/]
    inputs = (1..4).flat_map { |size| %W[a b \r \n].repeated_permutation(size).map(&:join) }

    patterns.each do |pattern|
      reference = Regexp.new("\\A(?:#{pattern.source})\\z")
      dfa = Flexr.compile_pattern(pattern)
      inputs.each do |input|
        expect(dfa.accept?(input)).to eq(reference.match?(input)), "#{pattern.inspect} on #{input.inspect}"
      end
    end
  end

  it "only accepts a final LF for the soft source end" do
    %i[table firstmatch].each do |mode|
      lexer = Class.new(Flexr::Lexer) do
        backend mode
        rule(/a\z/, emit: :END)
        rule(/a\Z/, emit: :FINAL_LINE_END)
        rule(/./m, emit: :OTHER)
      end

      expect(lexer.new(StringIO.new("a"), chunk_size: 1).next_token).to eq([:END, "a"])
      expect(lexer.new(StringIO.new("a\n"), chunk_size: 1).next_token).to eq([:FINAL_LINE_END, "a"])
      expect(lexer.new(StringIO.new("a\nb"), chunk_size: 1).next_token).to eq([:OTHER, "a"])
      expect(lexer.new(StringIO.new("a\r\n"), chunk_size: 1).next_token).to eq([:OTHER, "a"])
    end
  end

  it "keeps captures that depend on the active source ending instead of the loaded prefix" do
    %i[table firstmatch].each do |mode|
      lexer = Class.new(Flexr::Lexer) do
        backend mode
        rule(/(?<ending>a\z)|(?<final_line>a\Z)|(?<body>a)/) { emit :A, captures }
        rule(/./m, emit: :OTHER)
      end

      expect(lexer.new(StringIO.new("a"), chunk_size: 1).next_token)
        .to eq([:A, {ending: "a", final_line: nil, body: nil}])
      ["ab", "a\xff".b.force_encoding(Encoding::UTF_8), "a\n\xff".b.force_encoding(Encoding::UTF_8)].each do |input|
        expect(lexer.new(StringIO.new(input), chunk_size: 1).next_token)
          .to eq([:A, {ending: nil, final_line: nil, body: "a"}])
      end
    end
  end

  it "lets firstmatch backtrack to an earlier line end even when another branch looked ahead" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a(?=b)(?:b\nc|b)$/, emit: :AT_LINE_END)
      rule(/./m, emit: :OTHER)
    end

    expect(lexer.new(StringIO.new("ab\ncx"), chunk_size: 1).next_token).to eq([:AT_LINE_END, "ab"])
  end



  it "bounds the probe beyond a possible final LF" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a\Z/, emit: :END)
      rule(/./m, emit: :OTHER)
    end

    expect(lexer.new(StringIO.new("a\n"), chunk_size: 1, max_lookahead_size: 1).next_token).to eq([:END, "a"])
    expect { lexer.new(StringIO.new("a\nb"), chunk_size: 1, max_lookahead_size: 1).next_token }
      .to raise_error(Flexr::Runtime::LookaheadTooLargeError)
  end

  it "honors an absolute end assertion in a composable pattern" do
    lexer = Class.new(Flexr::Lexer) do
      rule(pattern(/a\z/) | pattern(/a$\nb/), emit: :RULE)
      rule(/./m, emit: :OTHER)
    end

    expect(lexer.recognizer.match("xa", 1)).to eq([:RULE, 2])
    expect(lexer.recognizer.match("xax", 1)).to eq([:OTHER, 2])
    expect(lexer.recognizer.match("xa\nb", 1)).to eq([:RULE, 4])
  end

  it "checks the child EOF before resuming a parent source" do
    lexer = Class.new(Flexr::Lexer) do
      option :input_stack
      rule("!") do
        push_input(StringIO.new("a"))
        emit :INCLUDE
      end
      rule(/a\z/, emit: :SOURCE_END)
      rule(/./m, emit: :OTHER)
    end

    expect(lexer.new(StringIO.new("!ax"), chunk_size: 1).tokens)
      .to eq([[:INCLUDE, "!"], [:SOURCE_END, "a"], [:OTHER, "a"], [:OTHER, "x"]])
  end
end
