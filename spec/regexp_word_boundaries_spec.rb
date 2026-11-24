# frozen_string_literal: true

require "open3"
require "stringio"

RSpec.describe "regexp word boundaries" do
  it "agrees with Ruby on whole matches at character and source boundaries" do
    patterns = [
      /\b/, /\B/, /\ba/, /a\b/, /a\B./, /\B./, /.\b./,
      /.\B./, /\b.\b/, /\b\w\b/, /.(?=\b.)\b./, /.(?<=.\b)./
    ]
    alphabet = ["a", "_", "é", "\u0301", "‿", "\u200D", "²", "௰", "😀", "!", "\n"]
    inputs = (0..2).flat_map { |length| alphabet.repeated_permutation(length).map(&:join) }

    patterns.each do |pattern|
      reference = Regexp.new("\\A(?:#{pattern.source})\\z", pattern.options)
      compiled = Flexr.compile_pattern(pattern, options: { allow_empty_match: true })
      inputs.each do |input|
        expect(compiled.accept?(input)).to eq(reference.match?(input)), "#{pattern.inspect} on #{input.inspect}"
      end
    end
  end

  it "keeps the previous scalar across discarded chunks and checks the next scalar past a token" do
    %i[table direct firstmatch].each do |mode|
      lexer = Class.new(Flexr::Lexer) do
        backend mode
        rule(/\bend\b/, emit: :KEYWORD)
        rule(/\Bend/, emit: :SUFFIX)
        rule(/end/, emit: :BARE)
        rule(/./m, skip: true)
      end

      input = StringIO.new("éend \u0301end end² end‿ end!")
      expect(lexer.new(input, chunk_size: 1, retain_input: false).tokens).to eq([
        [:SUFFIX, "end"], [:SUFFIX, "end"], [:BARE, "end"], [:BARE, "end"], [:KEYWORD, "end"]
      ])
    end
  end

  it "keeps capture replay inside lookbehind on the vendored Unicode version" do
    %i[table firstmatch].each do |mode|
      lexer = Class.new(Flexr::Lexer) do
        backend mode
        rule(/(?<edge>.(?<=.\b))|(?<plain>.)/) { emit :CHAR, captures }
      end

      input = StringIO.new("\u1C89 ")
      expect(lexer.new(input, chunk_size: 1, retain_input: false).next_token)
        .to eq([:CHAR, {edge: nil, plain: "\u1C89"}])
    end
  end

  it "uses ASCII word characters on binary input and keeps class backspace" do
    lexer = Class.new(Flexr::Lexer) do
      encoding Encoding::BINARY
      rule(/\ba\b/n, emit: :WORD)
      rule(/[\b]/n, emit: :BACKSPACE)
      rule(/./mn, skip: true)
    end

    expect(lexer.new("\xe9a\xff\ba_".b).tokens).to eq([[:WORD, "a".b], [:BACKSPACE, "\b".b]])
  end

  it "keeps only user captures in generated and standalone lexers" do
    Dir.mktmpdir("flexr-word-boundaries-") do |directory|
      spec = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      program = <<~'RUBY'
        require "stringio"
        load ARGV.fetch(0)
        tokens = WordBoundaryFixture.new(StringIO.new("\u1C89"), chunk_size: 1, retain_input: false).tokens
        expected = [[:CHAR, {FlexrWordBoundary0: nil, plain: "\u1C89"}]]
        abort tokens.inspect unless tokens == expected
      RUBY
      %i[table firstmatch].product([false, true]).each do |backend, standalone|
        File.write(spec, <<~RUBY)
          require "flexr"
          class WordBoundaryFixture < Flexr::Lexer
            backend :#{backend}
            rule(/(?<FlexrWordBoundary0>.(?<=.\\b))|(?<plain>.)/) { emit :CHAR, captures }
          end
        RUBY
        Flexr::Generator.new(spec, output: output, options: { standalone: standalone }).generate
        _, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", program, output)
        expect(status).to be_success, stderr
      end
    end
  end

  it "treats malformed UTF-8 as a non-word side during capture replay" do
    %i[table firstmatch].each do |mode|
      lexer = Class.new(Flexr::Lexer) do
        backend mode
        rule(/(?<edge>a)\b|(?<inside>a)\B/) { emit :LETTER, captures }
      end
      io = StringIO.new("a\xff".b)
      token = lexer.new(io, chunk_size: 1, retain_input: false, error_mode: :token).next_token
      expect(token).to eq([:LETTER, {edge: "a", inside: nil}])
    end
  end

  it "uses the active source boundary and restores parent history" do
    lexer = Class.new(Flexr::Lexer) do
      option :input_stack
      rule("a") do
        push_input(StringIO.new("end"))
        emit :INCLUDE
      end
      rule(/\bend\b/, emit: :KEYWORD)
      rule(/\Bend\b/, emit: :SUFFIX)
    end

    expect(lexer.new(StringIO.new("aend"), chunk_size: 1, retain_input: false).tokens).to eq([
      [:INCLUDE, "a"], [:KEYWORD, "end"], [:SUFFIX, "end"]
    ])
  end
end
