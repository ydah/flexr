# frozen_string_literal: true

require "json"
require "open3"
require "stringio"

RSpec.describe "shortest-match states" do
  it "compares body lengths and keeps the policy local to the state" do
    lexer = Class.new(Flexr::Lexer) do
      rule("a", followed_by: "bcd", emit: :A)
      rule("ab", emit: :AB)
      rule("abcde", emit: :ABCDE)

      state :raw, match: :shortest do
        rule("a", followed_by: "bcd", emit: :A)
        rule("ab", emit: :AB)
        rule("abcde", emit: :ABCDE)
        rule("bcde", emit: :REST)
      end
    end

    expect(lexer.new("abcde").next_token).to eq([:ABCDE, "abcde"])
    scanner = lexer.new("abcde")
    scanner.begin_state(:raw)
    expect(scanner.tokens).to eq([[:A, "a"], [:REST, "bcde"]])
  end

  it "ranks by priority and declaration order only at the selected body boundary" do
    lexer = Class.new(Flexr::Lexer) do
      state :initial, inclusive: true, match: :shortest do
        rule("a", followed_by: /b+/, emit: :CONTEXT)
        rule("a", emit: :FIRST, priority: 3)
        rule("a", followed_by: "b", emit: :SECOND, priority: 3)
        rule("ab", emit: :LATER, priority: 50)
      end
    end

    expect(lexer.new("abbb", max_lookahead_size: 1).next_token).to eq([:FIRST, "a"])
    expect(lexer.new("abbb").next_token(expect: %i[CONTEXT LATER])).to eq([:CONTEXT, "a"])
    expect(lexer.new("abbb").next_token(expect: [:LATER])).to eq([:LATER, "ab"])
  end

  it "continues to a longer body when the shorter body's trailer fails" do
    lexer = Class.new(Flexr::Lexer) do
      state :initial, inclusive: true, match: :shortest do
        rule("a", followed_by: "z", emit: :A)
        rule("ab", emit: :AB)
      end
    end

    expect(lexer.new("ab").next_token).to eq([:AB, "ab"])
  end

  it "requires a complete UTF-8 scalar and valid line anchors in a one-byte stream" do
    lexer = Class.new(Flexr::Lexer) do
      state :initial, inclusive: true, match: :shortest do
        rule(/\xC3/n, emit: :PARTIAL, priority: 10)
        rule(/^é$/, emit: :LINE)
        rule(/é[!\n]/, emit: :PAIR)
        rule("x", skip: true)
      end
    end

    scanner = ->(input) { lexer.new(StringIO.new(input), chunk_size: 1, retain_input: false) }
    expect(scanner.call("é\n").next_token).to eq([:LINE, "é".b])
    expect(scanner.call("é!").next_token).to eq([:PAIR, "é!".b])
    expect(scanner.call("xé\n").next_token).to eq([:PAIR, "é\n".b])
  end

  it "returns a selected token without another body read or scan step" do
    lexer = Class.new(Flexr::Lexer) do
      encoding Encoding::BINARY
      state :initial, inclusive: true, match: :shortest do
        rule(/a+/, emit: :A)
      end
    end
    input = Object.new
    chunks = ["a".b]
    input.define_singleton_method(:read) do |_length|
      chunks.shift || raise("read past the selected body")
    end

    expect(lexer.new(input, chunk_size: 1, max_steps: 2).next_token).to eq([:A, "a".b])
  end

  it "supplies the same body length and same-end rule in an action-free recognizer" do
    lexer = Class.new(Flexr::Lexer) do
      state :raw, match: :shortest do
        rule("a", followed_by: "bc", emit: :CONTEXT)
        rule("a", emit: :A, priority: 5)
        rule("abc", emit: :ABC, priority: 10)
      end
    end

    recognizer = lexer.recognizer(state: :raw)
    expect(recognizer.match("zabc", 1)).to eq([:A, 2])
    expect(Ractor.shareable?(recognizer)).to be(true)
  end

  it "rejects invalid and conflicting state policies" do
    expect do
      Class.new(Flexr::Lexer) { state(:raw, match: :fastest) { rule("a", emit: :A) } }
    end.to raise_error(ArgumentError, /match/)

    expect do
      Class.new(Flexr::Lexer) do
        state(:raw, match: :shortest) { rule("a", emit: :A) }
        state(:raw, match: :longest) { rule("b", emit: :B) }
      end
    end.to raise_error(ArgumentError, /match/)
  end

  it "rejects incomplete UTF-8 boundaries in both scanning and recognition" do
    lexer = Class.new(Flexr::Lexer) do
      state(:initial, inclusive: true, match: :shortest) do
        rule("a", emit: :BODY)
        rule("b", followed_by: "c", emit: :CONTEXT)
        rule(/d\xFF/n, emit: :RAW_BODY)
        rule("e", followed_by: /f\xFF/n, emit: :RAW_CONTEXT)
      end
    end
    recognizer = lexer.recognizer

    ["a\x80".b, "bc\x80".b, "d\xFF".b, "ef\xFF".b].each do |input|
      expect { lexer.new(input).next_token }.to raise_error(Flexr::LexError)
      expect(recognizer.match(input, 0)).to be_nil
    end
  end

  it "reports a compile error for shortest when the final backend is firstmatch" do
    lexer = Class.new(Flexr::Lexer) do
      state(:raw, match: :shortest) { rule(/a+/, emit: :A) }
      backend :firstmatch
    end

    expect { lexer.compile! }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E018")
    end
  end

  it "keeps captures, trailers, parser requests and default states across scanners" do
    Dir.mktmpdir("flexr-shortest-") do |directory|
      source = File.join(directory, "lexer.flexr.rb")
      File.write(source, <<~RUBY)
        require "flexr"
        class ShortestMatchArtifactLexer < Flexr::Lexer
          rule(/a+/, emit: :ALL)

          state :raw, match: :shortest do
            rule(/(?<head>a)(?<tail>a*)/, followed_by: "b", emits: :BODY) { emit :BODY, captures }
            rule(/a+/, emit: :ONE)
            rule("b", emit: :REST)
          end
        end
      RUBY

      variants = [[source, false]]
      %i[table direct].product([false, true]).each do |backend, standalone|
        artifact = File.join(directory, "lexer.#{backend}.#{standalone}.rb")
        Flexr::Generator.new(source, output: artifact, options: {backend: backend, standalone: standalone}).generate
        variants << [artifact, standalone]
      end

      runner = <<~RUBY
        require "json"
        require "stringio"
        load ARGV.fetch(0)
        default = ShortestMatchArtifactLexer.new("aaa").next_token
        raw = ShortestMatchArtifactLexer.new(StringIO.new("aab"), chunk_size: 1, retain_input: false)
        raw.begin_state(:raw)
        earliest = raw.next_token
        rest = raw.tokens
        filtered = ShortestMatchArtifactLexer.new("aab")
        filtered.begin_state(:raw)
        body = filtered.next_token(expect: [:BODY])
        puts JSON.generate([default, earliest, rest, body, filtered.tokens])
      RUBY
      expected = [%w[ALL aaa], %w[ONE a], [["BODY", {"head" => "a", "tail" => ""}], %w[REST b]],
                  ["BODY", {"head" => "a", "tail" => "a"}], [%w[REST b]]]
      variants.each do |path, standalone|
        command = [RbConfig.ruby]
        command << "-Ilib" unless standalone
        environment = standalone ? {"RUBYOPT" => nil, "RUBYLIB" => nil} : {}
        stdout, stderr, status = Open3.capture3(environment, *command, "-e", runner, path)
        expect(status).to be_success, stderr
        expect(JSON.parse(stdout)).to eq(expected), File.basename(path)
      end
    end
  end
end
