# frozen_string_literal: true

require "json"
require "open3"

RSpec.describe "action-free recognizers" do
  it "returns one match with source-order ties and never executes actions" do
    lexer = Class.new(Flexr::Lexer) do
      rule("if", emit: :IF)
      rule(/[a-z]+/, emit: :IDENT)
      rule(/ +/, skip: true)
      rule(/[0-9]+/) { raise "a recognizer must never execute an action" }
      on_eof { raise "a recognizer must never execute EOF" }
    end
    recognizer = lexer.recognizer
    input = "=if ifx 17"

    expect(recognizer.match(input, 0)).to be_nil
    expect(recognizer.match(input, 1)).to eq([:IF, 3])
    expect(recognizer.match(input, 4)).to eq([:IDENT, 7])
    expect(recognizer.match(input, 7)).to eq([2, 8])
    expect(recognizer.match(input, 8)).to eq([3, 10])
    expect(recognizer.match(input, input.bytesize)).to be_nil
    expect(recognizer.match(input, 4) { |rule, finish| rule == :IDENT && finish == 7 }).to be(true)
    expect(recognizer.match(input, 0) { raise "no match" }).to be_nil
  end

  it "uses trailing length for ranking and preserves line boundaries" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/^a$/, emit: :LINE)
      rule("a", followed_by: /bb/, emit: :CONTEXT)
      rule("ab", emit: :PAIR)
      rule("x\n", followed_by: /^y(?~ab)ab/, emit: :HEAD)
      rule("x", followed_by: /^y(?~ab)ab/, emit: :WRONG_LINE)
      rule("x", emit: :X)
    end
    recognizer = lexer.recognizer

    expect(recognizer.match("zabb\na\nx", 1)).to eq([:CONTEXT, 2])
    expect(recognizer.match("zabb\na\nx", 5)).to eq([:LINE, 6])
    expect(recognizer.match("za\n", 1)).to be_nil
    expect(recognizer.match("x\nyab", 0)).to eq([:HEAD, 2])
    expect(recognizer.match("xyab", 0)).to eq([:X, 1])
  end

  it "recognizes full UTF-8 scalars or raw bytes according to the lexer encoding" do
    utf8 = Class.new(Flexr::Lexer) { rule(/./m, emit: :CHAR) }.recognizer
    binary = Class.new(Flexr::Lexer) do
      encoding Encoding::BINARY
      rule(/./m, emit: :BYTE)
    end.recognizer

    expect(utf8.match("éa".b, 0)).to eq([:CHAR, 2])
    expect(utf8.match("éa".b, 1)).to be_nil
    expect(utf8.match("éa".b, 2)).to eq([:CHAR, 3])
    expect(utf8.match("\xED\xA0\x80".b, 0)).to be_nil
    expect(utf8.match("\xF0\x9F".b, 0)).to be_nil
    expect(binary.match("éa".b, 1)).to eq([:BYTE, 2])
  end

  it "rejects a trailing match ending inside a Unicode scalar" do
    lexer = Class.new(Flexr::Lexer) do
      rule("x", followed_by: /y(?~ab)\xC3/n, emit: :PARTIAL)
      rule("x", emit: :X)
    end

    expect(lexer.recognizer.match("xyé", 0)).to eq([:X, 1])
  end

  it "can snapshot an exclusive state and share it without its dynamic actions" do
    lexer = Class.new(Flexr::Lexer) do
      rule("a", emit: :A)
      captured = +"unshareable action state"
      state(:inside) do
        rule("a") { emit :DYNAMIC, captured }
      end
    end
    recognizer = lexer.recognizer(state: :inside)

    expect(lexer.recognizer.match("a", 0)).to eq([:A, 1])
    expect(recognizer.match("a", 0)).to eq([1, 1])
    expect(Ractor.shareable?(recognizer)).to be(true)
    expect { lexer.recognizer(state: :unknown) }.to raise_error(ArgumentError, /state/)
  end

  it "returns the rule's static identity before keyword classification" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/[a-z]+/, emit: :IDENT)
      keywords %w[if], among: :IDENT
    end

    expect(lexer.new("if").tokens).to eq([[:IF, "if"]])
    expect(lexer.recognizer.match("if", 0)).to eq([:IDENT, 2])
  end

  it "exposes explicitly enabled zero-width matches at non-EOF positions" do
    lexer = Class.new(Flexr::Lexer) do
      option :allow_empty_match
      rule(//, skip: true)
    end

    expect(lexer.recognizer.match("x", 0)).to eq([0, 0])
    expect(lexer.recognizer.match("x", 1)).to be_nil
  end

  it "validates the input and refuses native firstmatch semantics" do
    lexer = Class.new(Flexr::Lexer) { rule("x", emit: :X) }
    recognizer = lexer.recognizer
    expect { recognizer.match(nil, 0) }.to raise_error(TypeError)
    expect { recognizer.match("x", 0.0) }.to raise_error(TypeError)
    expect { recognizer.match("x", -1) }.to raise_error(RangeError)
    expect { recognizer.match("x", 2) }.to raise_error(RangeError)

    firstmatch = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a|ab/, emit: :A)
    end
    expect { firstmatch.recognizer }.to raise_error(ArgumentError, /firstmatch/)
  end

  it "matches the same offsets in runtime, static generated and standalone lexers" do
    Dir.mktmpdir("flexr-recognizer") do |dir|
      source = File.join(dir, "lexer.flexr.rb")
      generated = File.join(dir, "lexer.generated.rb")
      standalone = File.join(dir, "lexer.standalone.rb")
      File.write(source, <<~RUBY)
        require "flexr"
        class RecognizerFixture < Flexr::Lexer
          rule("a", followed_by: "bc", emit: :CONTEXT)
          rule("ab", emit: :PAIR)
          rule("é") { raise "recognizer executed a dynamic action" }
        end
      RUBY
      Flexr::Generator.new(source, output: generated).generate
      Flexr::Generator.new(source, output: standalone, options: { standalone: true }).generate
      script = <<~RUBY
        require "json"
        load ARGV.fetch(0)
        recognizer = RecognizerFixture.recognizer
        abort "recognizer must be shareable" unless Ractor.shareable?(recognizer)
        worker = Ractor.new(recognizer) { |shared| shared.match("é", 0) }
        result = worker.respond_to?(:value) ? worker.value : worker.take
        abort "wrong match from a Ractor" unless result == [2, 2]
        puts JSON.generate([recognizer.match("zabc", 1), recognizer.match("ab", 0),
                            recognizer.match("é", 0), recognizer.match("é", 1)])
      RUBY

      [source, generated, standalone].each do |path|
        command = [RbConfig.ruby]
        command.push("-Ilib") unless path == standalone
        stdout, stderr, status = Open3.capture3(*command, "-e", script, path)
        expect(status).to be_success, stderr
        expect(JSON.parse(stdout)).to eq([["CONTEXT", 2], ["PAIR", 2], [2, 2], nil])
      end
    end
  end
end
