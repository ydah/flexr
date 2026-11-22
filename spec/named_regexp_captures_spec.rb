# frozen_string_literal: true

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

  def outcomes(source, input)
    Dir.mktmpdir("flexr-captures-") do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      generated = File.join(directory, "lexer.generated.rb")
      standalone = File.join(directory, "lexer.standalone.rb")
      File.binwrite(path, source)
      Flexr::Generator.new(path, output: generated).generate
      Flexr::Generator.new(path, output: standalone, options: { standalone: true }).generate

      runner = <<~RUNNER
        require "json"
        require "stringio"
        load ARGV.fetch(0)
        input = StringIO.new(ARGV.fetch(1))
        lexer = NamedCaptureLexer.new(input, retain_input: false, chunk_size: 1)
        puts JSON.generate(lexer.tokens)
      RUNNER
      [path, generated, standalone].map do |file|
        command = [RbConfig.ruby]
        command << "-Ilib" unless file == standalone
        stdout, stderr, status = Open3.capture3(*command, "-e", runner, file, input)
        expect(status).to be_success, stderr
        JSON.parse(stdout)
      end
    end
  end
end
