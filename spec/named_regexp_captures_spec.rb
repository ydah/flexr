# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

RSpec.describe "named regexp captures" do
  it "captures fields from the lexeme selected by the DFA" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/(?<whole>[0-9]+)\.(?<fraction>[0-9]+)/) do
        emit :FLOAT, [captures[:whole], captures[:fraction]]
      end
      rule(/ /, skip: true)
    end

    expect(lexer.new("12.34 5.6").tokens).to eq([[:FLOAT, %w[12 34]], [:FLOAT, %w[5 6]]])
  end

  it "returns nil for an optional group and does not reuse the previous capture" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/[0-9]+(?<unit>[KM])?/) { emit :SIZE, captures[:unit] }
      rule(/ /, skip: true)
    end

    expect(lexer.new("12K 44").tokens).to eq([[:SIZE, "K"], [:SIZE, nil]])
  end

  it "returns immutable values scoped to the current action" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/(?<whole>a)(?<optional>b)?/) { emit :CAPTURE, captures }
      rule("!") { emit :PLAIN, captures }
      on_eof { emit :EOF, captures }
    end

    scanner = lexer.new("ab!")
    first = scanner.next_token.last
    expect(first).to eq({ whole: "a", optional: "b" })
    expect(first).to be_frozen
    expect(first.values).to all(be_frozen)
    expect(scanner.captures).to be_empty
    expect(scanner.tokens).to eq([[:PLAIN, {}], [:EOF, {}]])
  end

  it "uses the winning pattern and original body across streaming and action controls" do
    source = <<~RUBY
      require "flexr"
      class NamedCaptureLexer < Flexr::Lexer
        rule([/^(?<leading>ab)/, /(?'middle'ab)/], followed_by: /(?<lookahead>,)/) do
          less(1) if text.start_with?("!")
          emit :WORD, [text, captures]
        end
        rule("!") { more }
        rule(/[b, ]/, skip: true)
      end
    RUBY

    rows = outcomes(source, "ab, !ab,")
    expect(rows).to all(eq([["WORD", ["ab", { "leading" => "ab" }]], ["WORD", ["!a", { "middle" => "ab" }]]]))
  end

  it "uses the native firstmatch choice and the DFA's longest match otherwise" do
    source = <<~RUBY
      require "flexr"
      class NamedCaptureLexer < Flexr::Lexer
        rule(/(?<part>a|ab)/) { emit :CAPTURE, captures[:part] }
        rule("b", emit: :B)
      end
    RUBY

    expect(outcomes(source, "ab")).to all(eq([%w[CAPTURE ab]]))
    firstmatch = source.sub("rule(/", "backend :firstmatch\n  option :experimental\n  rule(/")
    expect(outcomes(firstmatch, "ab")).to all(eq([%w[CAPTURE a], %w[B b]]))
  end

  it "replays only the selected rule's captures after applying expectations and priority" do
    source = <<~RUBY
      require "flexr"
      class NamedCaptureLexer < Flexr::Lexer
        rule(/(?<head>a)/, followed_by: "b", emits: :CONTEXT, priority: 2) { emit :CONTEXT, captures }
        rule(/a(?<tail>b)/, emits: :PAIR, priority: 10) { emit :PAIR, captures }
        rule(/(?<whole>abc)/, emits: :LONG) { emit :LONG, captures }
      end
    RUBY
    requests = [%i[CONTEXT PAIR], [:CONTEXT], %i[CONTEXT PAIR LONG]]
    expected = [["PAIR", { "tail" => "b" }], ["CONTEXT", { "head" => "a" }], ["LONG", { "whole" => "abc" }]]

    %i[table direct].each do |backend|
      expect(outcomes(source, "abc", requests: requests, backend: backend)).to all(eq(expected))
    end
  end

  it "uses native firstmatch capture data for the first eligible pattern" do
    source = <<~RUBY
      require "flexr"
      class NamedCaptureLexer < Flexr::Lexer
        backend :firstmatch
        rule(/(?<earlier>ab)/, emits: :EARLY) { emit :EARLY, captures }
        rule(/(?<later>a|ab)/, emits: :KEEP) { emit :KEEP, captures }
      end
    RUBY

    expect(outcomes(source, "ab", requests: [[:KEEP]])).to all(eq([["KEEP", { "later" => "a" }]]))
  end

  it "clears captures and restores the direct scanner layout across state changes" do
    source = <<~RUBY
      require "flexr"
      class NamedCaptureLexer < Flexr::Lexer
        rule(/(?<part>a)/) do
          push(:inside)
          emit :CAPTURE, captures
        end
        state(:inside) do
          rule("b") do
            pop
            emit :PLAIN, captures
          end
        end
      end
    RUBY

    expected = [["CAPTURE", { "part" => "a" }], ["PLAIN", {}]] * 2
    expect(outcomes(source, "abab", backend: :direct)).to all(eq(expected))
  end

  it "preserves captures for a rule that would otherwise use a whole-token plan" do
    lexer = Class.new(Flexr::Lexer) do
      accel :strscan
      rule(/(?<part>[a-z]+)/) { emit :WORD, captures[:part] }
    end

    expect(lexer.compile!.machines.fetch(:initial).whole_tokens).to be_nil
    expect(lexer.new("capture").tokens).to eq([[:WORD, "capture"]])
  end

  it "captures a value matched with vendored Unicode shorthands" do
    source = <<~'RUBY'
      require "flexr"
      class NamedCaptureLexer < Flexr::Lexer
        option :unicode
        rule(/(?<digit>\d)/) { emit :DIGIT, captures[:digit] }
      end
    RUBY

    expect(outcomes(source, "١")).to all(eq([%w[DIGIT ١]]))
  end

  it "supports capture replay across duplicate names and inline regexp options" do
    source = <<~RUBY
      require "flexr"
      class NamedCaptureLexer < Flexr::Lexer
        rule(/(?x)(?:(?<part>ab)|(?<part>(?i:C))) # trailing comment
            /) { emit :VALUE, captures[:part] }
        rule(" ", skip: true)
      end
    RUBY

    expect(outcomes(source, "ab c")).to all(eq([%w[VALUE ab], %w[VALUE c]]))
  end

  it "captures byte values in binary lexers" do
    source = <<~'RUBY'
      require "flexr"
      class NamedCaptureLexer < Flexr::Lexer
        encoding Encoding::BINARY
        rule(/(?<part>[\xF0-\xFF])/n) { emit :BYTE, captures[:part].bytes }
      end
    RUBY

    expect(outcomes(source, "\xFF".b)).to all(eq([["BYTE", [255]]]))
  end

  it "captures the body of the absence example" do
    source = <<~RUBY
      require "flexr"
      class NamedCaptureLexer < Flexr::Lexer
        rule(%r{<script>(?<body>(?~</script>))</script>}) { emit :SCRIPT, captures[:body] }
      end
    RUBY

    expect(outcomes(source, "<script>é\n</script><script></script>"))
      .to all(eq([["SCRIPT", "é\n"], ["SCRIPT", ""]]))
  end

  it "uses Ruby's group choices when more than one partition fits the body" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/(?<left>a|ab)(?<right>b?)/) { emit :CAPTURE, captures }
    end

    expect(lexer.new("ab").tokens).to eq([[:CAPTURE, { left: "a", right: "b" }]])
  end

  it "leaves captures nil in an absence branch with an empty DFA language" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/b(?<absent>(?~(?<excluded>a?)))|(?<present>b)/) { emit :CAPTURE, captures }
    end

    expect(lexer.new("b").tokens).to eq([[:CAPTURE, { absent: nil, excluded: nil, present: "b" }]])
  end

  it "requires runtimes loading an artifact with named captures to support them" do
    Dir.mktmpdir("flexr-capture-abi-") do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      generated = File.join(directory, "lexer.generated.rb")
      File.binwrite(path, <<~RUBY)
        require "flexr"
        class NamedCaptureLexer < Flexr::Lexer
          rule(/(?<part>ab)/) { emit :VALUE, captures[:part] }
        end
      RUBY
      Flexr::Generator.new(path, output: generated).generate

      runner = <<~RUBY
        require "flexr"
        Flexr::Runtime.send(:remove_const, :Captures)
        begin
          load ARGV.fetch(0)
        rescue Flexr::CompileError => error
          puts error.diagnostic.code
          puts error.diagnostic.note
        end
      RUBY
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", runner, generated)
      expect(status).to be_success, stderr
      expect(stdout).to include("FLEXR-E020", "runtime does not support named regexp captures")
    end
  end

  def outcomes(source, input, requests: nil, backend: nil)
    Dir.mktmpdir("flexr-captures-") do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      generated = File.join(directory, "lexer.generated.rb")
      standalone = File.join(directory, "lexer.standalone.rb")
      File.binwrite(path, source)
      options = backend ? { backend: backend } : {}
      Flexr::Generator.new(path, output: generated, options: options).generate
      Flexr::Generator.new(path, output: standalone, options: options.merge(standalone: true)).generate

      runner = <<~RUNNER
        require "json"
        require "stringio"
        load ARGV.fetch(0)
        STDIN.binmode
        requests = JSON.parse(STDIN.gets)
        input = STDIN.read
        make_lexer = -> { NamedCaptureLexer.new(StringIO.new(input), retain_input: false, chunk_size: 1) }
        tokens = if requests
          requests.map do |types|
            make_lexer.call.next_token(expect: types.map(&:to_sym))
          end
        else
          make_lexer.call.tokens
        end
        puts JSON.generate(tokens)
      RUNNER
      [path, generated, standalone].map do |file|
        command = [RbConfig.ruby]
        command << "-Ilib" unless file == standalone
        data = [JSON.generate(requests), input.b].join("\n")
        stdout, stderr, status = Open3.capture3(*command, "-e", runner, file, stdin_data: data, binmode: true)
        expect(status).to be_success, stderr
        JSON.parse(stdout)
      end
    end
  end
end
