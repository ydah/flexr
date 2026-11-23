# frozen_string_literal: true

require "open3"
require "stringio"

RSpec.describe "regexp left anchors" do
  it "agrees with Ruby on whole matches including nested source and line starts" do
    patterns = [
      /\Aa/, /a\n^b/, /a\n^/, /a\A/, /a(?=\n^b)\nb/, /(?:a|\A)b/, /a\n(?:^b|c)/,
      /^a|b/, /a|^b/, /a^b/, /a(?!\A)b/, /(?:\A?a|\n^b){2}/
    ]
    inputs = (0..4).flat_map { |size| %W[a b c \n].repeated_permutation(size).map(&:join) }

    patterns.each do |pattern|
      reference = Regexp.new("\\A(?:#{pattern.source})\\z")
      dfa = Flexr.compile_pattern(pattern)
      inputs.each do |input|
        expect(dfa.accept?(input)).to eq(reference.match?(input)), "#{pattern.inspect} on #{input.inspect}"
      end
    end
  end

  it "distinguishes the start of each source from later line starts on streamed input" do
    %i[table direct auto firstmatch].each do |mode|
      lexer = Class.new(Flexr::Lexer) do
        backend mode
        option :input_stack
        rule("!") do
          push_input(StringIO.new("a\na"))
          emit :INCLUDE
        end
        rule(/\Aa/, emit: :SOURCE_START)
        rule(/(?:^a|b)/, emit: :LINE_START)
        rule(/./m, emit: :OTHER)
      end

      actual = lexer.new(StringIO.new("a!a\na"), chunk_size: 1).tokens
      expect(actual).to eq([[:SOURCE_START, "a"], [:INCLUDE, "!"], [:SOURCE_START, "a"], [:OTHER, "\n"],
                            [:LINE_START, "a"], [:OTHER, "a"], [:OTHER, "\n"], [:LINE_START, "a"]])
    end
  end

  it "uses the recognizer's supplied byte offset inside a composable pattern" do
    lexer = Class.new(Flexr::Lexer) do
      rule(pattern(/\Aa/) | pattern(/(?:^a|b)/), emit: :AT_START)
      rule(/./m, emit: :OTHER)
    end

    expect(lexer.recognizer.match("a", 0)).to eq([:AT_START, 1])
    expect(lexer.recognizer.match("xa", 1)).to eq([:OTHER, 2])
    expect(lexer.recognizer.match("\na", 1)).to eq([:AT_START, 2])
  end

  it "replays the capture branch at the active source position" do
    %i[table firstmatch].each do |mode|
      lexer = Class.new(Flexr::Lexer) do
        backend mode
        rule(/é/, skip: true)
        rule(/(?<first>\Aa)|(?<line>^a)|(?<other>a)/) { emit :A, captures }
        rule(/./m, skip: true)
      end

      input = StringIO.new("aéa\na")
      expect(lexer.new(input, chunk_size: 1).tokens).to eq([
        [:A, {first: "a", line: nil, other: nil}],
        [:A, {first: nil, line: nil, other: "a"}],
        [:A, {first: nil, line: "a", other: nil}]
      ])
    end
  end

  it "checks line starts inside trailing context at the candidate endpoint" do
    %i[table firstmatch].each do |mode|
      lexer = Class.new(Flexr::Lexer) do
        backend mode
        rule(/a\n/, followed_by: /(?:^b|c)/, emit: :WITH_CONTEXT)
        rule(/./m, emit: :OTHER)
      end

      expect(lexer.new(StringIO.new("a\nb"), chunk_size: 1).next_token).to eq([:WITH_CONTEXT, "a\n"])
      expect(lexer.recognizer.match("xa\nb", 1)).to eq([:WITH_CONTEXT, 3]) unless mode == :firstmatch
    end
  end

  it "bounds the probe beyond a line feed at the candidate endpoint" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a\n^/, emit: :LINE)
      rule(/./m, emit: :OTHER)
    end

    expect { lexer.new("a\nb", max_lookahead_size: 0).next_token }
      .to raise_error(Flexr::Runtime::LookaheadTooLargeError)
    expect(lexer.new("a\nb", max_lookahead_size: 1).next_token).to eq([:LINE, "a\n"])
  end

  it "rejects an empty match that is possible only away from the source start" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/(?!\A)(?=a)/, emit: :EMPTY)
    end

    expect { lexer.compile! }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E005")
    end
  end

  it "serializes the active source checks in generated and standalone lexers" do
    Dir.mktmpdir("flexr-left-anchors-") do |directory|
      source = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      program = <<~'RUBY'
        require "stringio"
        load ARGV.fetch(0)
        lexer = LeftAnchorFixture.new(StringIO.new("axa\na"), chunk_size: 1)
        expected = [[:SOURCE, "a"], [:OTHER, "a"], [:LINE, "a"]]
        actual = lexer.tokens
        abort actual.inspect unless actual == expected
      RUBY
      %i[table direct firstmatch].product([true, false]).each do |mode, standalone|
        File.write(source, <<~RUBY)
          require "flexr"
          class LeftAnchorFixture < Flexr::Lexer
            backend :#{mode}
            rule(/\\Aa/, emit: :SOURCE)
            rule(/(?=(?:^a|b))[ab]/, emit: :LINE)
            rule(/a/, emit: :OTHER)
            rule(/./m, skip: true)
          end
        RUBY
        Flexr::Generator.new(source, output: output, options: { standalone: standalone }).generate
        _, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", program, output)
        expect(status).to be_success, "#{mode}, standalone=#{standalone}: #{stderr}"
      end
    end
  end
end
