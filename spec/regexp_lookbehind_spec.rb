# frozen_string_literal: true

require "open3"
require "stringio"

RSpec.describe "regexp lookbehind" do
  it "agrees with Ruby on whole matches that use fixed-width assertions" do
    patterns = [
      /a(?<=a)b/, /a(?<!a)b/, /.(?<!a)b/m, /(?<=a)b/, /(?<!a)b/,
      /a(?:b(?<=ab)|a(?<!ab))/, /.(?<=é)b/m, /a\n(?<=\n)b/
    ]
    inputs = (0..4).flat_map { |size| %W[a b é \n].repeated_permutation(size).map(&:join) }

    patterns.each do |pattern|
      reference = Regexp.new("\\A(?:#{pattern.source})\\z", pattern.options)
      compiled = Flexr.compile_pattern(pattern)
      inputs.each do |input|
        expect(compiled.accept?(input)).to eq(reference.match?(input)), "#{pattern.inspect} on #{input.inspect}"
      end
    end
  end

  it "accepts a variable-width body that ends at the assertion position" do
    positive = Flexr.compile_pattern('[=(,] *(?<=[=(,] *)/x')
    negative = Flexr.compile_pattern('[=(,] *(?<![=(,] *)/x')

    expect(positive.accept?("=/x")).to be(true)
    expect(positive.accept?("=   /x")).to be(true)
    expect(negative.accept?("=   /x")).to be(false)
    expect(Flexr.compile_pattern('a+b(?<!a+)/x').accept?("aaab/x")).to be(true)
  end

  it "advances lookbehind over discarded bytes and skipped tokens" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/[=(,]/, emit: :OPERATOR)
      rule(/ +/, skip: true)
      rule(pattern(regexp: '(?<=[=(,]\s*)/[^/]+/'), emit: :REGEXP)
      rule(/./m, emit: :OTHER)
    end

    io = StringIO.new("=   /a/  /b/")
    expect(lexer.new(io, chunk_size: 1, retain_input: false).tokens).to eq([
      [:OPERATOR, "="], [:REGEXP, "/a/"], [:OTHER, "/"], [:OTHER, "b"], [:OTHER, "/"]
    ])
  end

  it "starts each pushed source with empty history and restores the parent's history" do
    lexer = Class.new(Flexr::Lexer) do
      option :input_stack
      rule("!") do
        push_input(StringIO.new("xax"))
        emit :INCLUDE
      end
      rule(/(?<=a)x/, emit: :AFTER_A)
      rule(/(?<=!)x/, emit: :AFTER_INCLUDE)
      rule(/./, emit: :OTHER)
    end

    input = StringIO.new("!x")
    expect(lexer.new(input, chunk_size: 1, retain_input: false).tokens).to eq([
      [:INCLUDE, "!"], [:OTHER, "x"], [:OTHER, "a"], [:AFTER_A, "x"], [:AFTER_INCLUDE, "x"]
    ])
  end

  it "uses the same history for nested lookbehind and lookahead" do
    expect(Flexr.compile_pattern('xa(?<=(?<=x)a)b').accept?("xab")).to be(true)
    expect(Flexr.compile_pattern('a(?=(?<=a)b)b').accept?("ab")).to be(true)
    expect(Flexr.compile_pattern('a(?<=a(?=b))b').accept?("ab")).to be(true)
    expect(Flexr.compile_pattern('a(?<!a(?=b))[bc]').accept?("ac")).to be(true)
    expect(Flexr.compile_pattern('a(?<!a(?=b))[bc]').accept?("ab")).to be(false)
  end

  it "replays fixed-width Ruby lookbehind captures after the original bytes are discarded" do
    %i[table firstmatch].each do |mode|
      lexer = Class.new(Flexr::Lexer) do
        backend mode
        rule(/é/, skip: true)
        rule(/(?<=(?<prefix>é))(?<body>a)|(?<fallback>a)/) { emit :LETTER, captures }
      end

      io = StringIO.new("éaa")
      expect(lexer.new(io, chunk_size: 1, retain_input: false).tokens).to eq([
        [:LETTER, {prefix: "é", body: "a", fallback: nil}],
        [:LETTER, {prefix: nil, body: nil, fallback: "a"}]
      ])
    end
  end

  it "treats malformed bytes as occupied source positions during capture replay" do
    %i[table firstmatch].each do |mode|
      lexer = Class.new(Flexr::Lexer) do
        backend mode
        rule(/(?<=.)(?<after_character>a)|(?<other>a)/) { emit :LETTER, captures }
      end
      malformed = StringIO.new("\xffa".b)
      actual = lexer.new(malformed, chunk_size: 1, retain_input: false, error_mode: :token).tokens
      expect(actual.last).to eq([:LETTER, {after_character: nil, other: "a"}])
    end
  end

  it "keeps a lookbehind line anchor relative to the real end of the source" do
    %i[table firstmatch].each do |mode|
      lexer = Class.new(Flexr::Lexer) do
        backend mode
        rule(/(?<line>a)(?<=a$)|(?<other>a)/) { emit :LETTER, captures }
      end

      expect(lexer.new("a").tokens).to eq([[:LETTER, {line: "a", other: nil}]])
      malformed = StringIO.new("a\xff".b)
      actual = lexer.new(malformed, chunk_size: 1, retain_input: false, error_mode: :token).tokens
      expect(actual.first).to eq([:LETTER, {line: nil, other: "a"}])
    end
  end

  it "uses the caller's prefix when recognizing or seeking to a byte offset" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/(?<=aa)b/, emit: :AFTER_A)
      rule(/./m, emit: :OTHER)
    end

    expect(lexer.recognizer.match("aab", 2)).to eq([:AFTER_A, 3])
    expect(lexer.recognizer.match("axb", 2)).to eq([:OTHER, 3])

    scan = lexer.new("aabab")
    scan.seek(2)
    bookmark = scan.checkpoint
    expect(scan.next_token).to eq([:AFTER_A, "b"])
    scan.seek(4)
    expect(scan.next_token).to eq([:OTHER, "b"])
    scan.restore(bookmark)
    expect(scan.next_token).to eq([:AFTER_A, "b"])
  end

  it "checks history through pattern algebra and trailing context" do
    lexer = Class.new(Flexr::Lexer) do
      command = pattern(regexp: '(?<=a+)b') & /[bc]/
      rule(pattern("a") + command, emit: :COMMAND)
      rule(/x/, followed_by: /(?<=x)y/, emit: :WITH_CONTEXT)
      rule(/./, emit: :OTHER)
    end

    expect(lexer.new(StringIO.new("abxy"), chunk_size: 1, retain_input: false).tokens)
      .to eq([[:COMMAND, "ab"], [:WITH_CONTEXT, "x"], [:OTHER, "y"]])
  end

  it "reflects edits to the retained prefix when the input string is live" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/(?<=a)b/, emit: :AFTER_A)
      rule(/./, emit: :OTHER)
    end

    input = +"ab"
    scan = lexer.new(input, freeze_input: false)
    expect(scan.next_token).to eq([:OTHER, "a"])
    input.setbyte(0, "x".ord)
    expect(scan.next_token).to eq([:OTHER, "b"])
  end

  it "keeps variable-width lookbehind in generated and standalone lexers" do
    Dir.mktmpdir("flexr-lookbehind-") do |directory|
      spec = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      File.write(spec, <<~RUBY)
        require "flexr"
        class LookbehindFixture < Flexr::Lexer
          rule(pattern(regexp: '(?<=a +)b'), emit: :AFTER_A)
          rule(/./m, skip: true)
        end
      RUBY
      program = <<~RUBY
        require "stringio"
        load ARGV.fetch(0)
        tokens = LookbehindFixture.new(StringIO.new("a    bb"), chunk_size: 1, retain_input: false).tokens
        abort tokens.inspect unless tokens == [[:AFTER_A, "b"]]
      RUBY
      [false, true].each do |standalone|
        Flexr::Generator.new(spec, output: output, options: { standalone: standalone }).generate
        _, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", program, output)
        expect(status).to be_success, stderr
      end
    end
  end
end
