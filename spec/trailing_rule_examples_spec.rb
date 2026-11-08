# frozen_string_literal: true

require "open3"
require "rbconfig"
require "stringio"

RSpec.describe "trailing context rule examples" do
  def lexer_class(backend = :table, &rules)
    Class.new(Flexr::Lexer) do
      backend backend
      option :experimental if backend == :firstmatch
      class_eval(&rules)
    end
  end

  def warnings(lexer)
    lexer.compile!.diagnostics.select { |item| item.code == "FLEXR-W001" }
  end

  %i[table direct auto firstmatch].each do |backend|
    it "includes the shortest trailing input for #{backend}" do
      lexer = lexer_class(backend) do
        rule(/a/, followed_by: /b+/, emit: :A)
        rule(/a/, followed_by: /b+/, emit: :HIDDEN)
        rule(/b/, emit: :B)
      end

      expect(warnings(lexer).first.note).to include(
        'example: "ab" selects rule /a/, followed_by: /b+/', "matched 1 byte, looked ahead 1 byte"
      )
      expect(lexer.new("ab").tokens).to eq([[:A, "a"], [:B, "b"]])
    end
  end

  it "does not claim that body-only shadowers win when lookahead changes the winner" do
    lexer = lexer_class do
      rule(/a/, followed_by: /c/, emit: :WRONG)
      rule(/a/, followed_by: /b/, emit: :A)
      rule(/a/, followed_by: /b/, emit: :HIDDEN)
    end

    expect(warnings(lexer).length).to eq(1)
    expect(warnings(lexer).first.message).to eq("rule /a/, followed_by: /b/ is unreachable")
    expect(warnings(lexer).first.note).to include('"ab" selects rule /a/, followed_by: /b/')
    expect(lexer.new("ab").next_token).to eq([:A, "a"])
  end

  it "removes a false warning when trailing context gives the target a longer match" do
    lexer = lexer_class do
      rule(/a/, emit: :PLAIN)
      rule(/a/, followed_by: /b/, emit: :CONTEXT)
    end

    expect(warnings(lexer)).to be_empty
    expect(lexer.new("ab").next_token).to eq([:CONTEXT, "a"])
  end

  it "keeps firstmatch priority even when a later rule has longer trailing context" do
    lexer = lexer_class(:firstmatch) do
      rule(/a/, emit: :PLAIN)
      rule(/a/, followed_by: /b/, emit: :HIDDEN)
    end

    expect(warnings(lexer).first.note).to include(
      '"ab" selects rule /a/', "first match wins, matched 1 byte, looked ahead 0 bytes"
    )
    expect(lexer.new("ab").next_token).to eq([:PLAIN, "a"])
  end

  it "compares the full input against rules with longer bodies" do
    lexer = lexer_class do
      rule(/abc/, emit: :WORD)
      rule(/a/, followed_by: /b/, emit: :CONTEXT)
      rule(/a/, followed_by: /bc/, emit: :HIDDEN)
    end

    expect(warnings(lexer).first.note).to include('"abc" selects rule /abc/', "matched 3 bytes, looked ahead 0 bytes")
    expect(lexer.new("abc").next_token).to eq([:WORD, "abc"])
  end

  it "uses rule order when the body and lookahead split differ but total lengths tie" do
    lexer = lexer_class do
      rule(/a/, followed_by: /bc/, emit: :SHORT)
      rule(/ab/, emit: :BODY)
      rule(/ab/, followed_by: /c/, emit: :HIDDEN)
    end

    expect(warnings(lexer).first.note).to include(
      '"abc" selects rule /a/, followed_by: /bc/', "matched 1 byte, looked ahead 2 bytes"
    )
    expect(lexer.new("abc").next_token).to eq([:SHORT, "a"])
  end

  it "keeps the longest body when several body/lookahead splits have the same total length" do
    lexer = lexer_class do
      rule(/a+/, followed_by: /a+/, emit: :A)
      rule(/aaa/, followed_by: /a/, emit: :HIDDEN)
    end

    expect(warnings(lexer).first.note).to include('"aaaa"', "matched 3 bytes, looked ahead 1 byte")
    expect(lexer.new("aaaa").next_token).to eq([:A, "aaa"])
  end

  it "checks end anchors in both the body and trailing context" do
    lexer = lexer_class do
      rule(/a$/, followed_by: /b/, emit: :ANCHORED)
      rule(/a/, followed_by: /b$/, emit: :A)
      rule(/a/, followed_by: /b$/, emit: :HIDDEN)
    end

    expect(warnings(lexer).length).to eq(1)
    expect(warnings(lexer).first.note).to include('"ab" selects rule /a/, followed_by: /b$/')
    expect(lexer.new("ab").next_token).to eq([:A, "a"])
  end

  it "keeps Unicode examples readable and reports byte lengths" do
    lexer = lexer_class do
      option :unicode
      rule(/é/, followed_by: /日/, emit: :E)
      rule(/é/, followed_by: /日/, emit: :HIDDEN)
    end

    expect(warnings(lexer).first.note).to include('"é日"', "matched 2 bytes, looked ahead 3 bytes")
    expect(lexer.new("é日").next_token).to eq([:E, "é"])
  end

  it "escapes binary trailing input" do
    lexer = lexer_class do
      encoding Encoding::BINARY
      rule(/a/, followed_by: /\xFF/n, emit: :A)
      rule(/a/, followed_by: /\xFF/n, emit: :HIDDEN)
    end

    expect(warnings(lexer).first.note).to include('"a\xFF"', "looked ahead 1 byte")
    expect(lexer.new("a\xff".b).next_token).to eq([:A, "a"])
  end

  it "omits an example if the runtime cannot compile the trailing matcher" do
    lexer = lexer_class do
      rule(/a/, followed_by: /b*/, emit: :A)
      rule(/a/, followed_by: /b*/, emit: :HIDDEN)
    end

    expect(warnings(lexer).first.note).to be_nil
  end

  it "does not split a UTF-8 character between the body and lookahead" do
    lexer = lexer_class do
      rule(/\xC3/n, followed_by: /\xA9/n, emit: :BYTE)
      rule(/\xC3/n, followed_by: /\xA9/n, emit: :HIDDEN)
    end

    expect(warnings(lexer).first.note).to be_nil
  end

  it "uses nonempty trailing input for an empty body" do
    lexer = lexer_class do
      option :allow_empty_match
      rule(//, followed_by: /b/, emit: :EMPTY)
      rule(//, followed_by: /b/, emit: :HIDDEN)
    end

    expect(warnings(lexer).first.note).to include('"b"', "matched 0 bytes, looked ahead 1 byte")
    expect(lexer.new("b").next_token).to eq([:EMPTY, ""])
  end

  it "omits warnings for rules reachable in another state with trailing context" do
    lexer = lexer_class do
      rule(/ab/, emit: :INITIAL)
      state :word do
        rule(/ab/, followed_by: /c/, emit: :CONTEXT)
      end
      all_states { rule(/ab/, emit: :TARGET) }
    end

    expect(warnings(lexer)).to be_empty
    scanner = lexer.new("ab")
    scanner.begin_state(:word)
    expect(scanner.tokens).to eq([[:TARGET, "ab"]])
  end

  it "does not execute actions while checking an example in a named state" do
    actions = []
    lexer = lexer_class do
      state :word do
        rule(/a/, followed_by: /b/) do
          actions << :A
          emit :A
        end
        rule(/a/, followed_by: /b/, emit: :HIDDEN)
      end
    end

    expect(warnings(lexer).first.note).to include("in state :word")
    expect(actions).to be_empty
    scanner = lexer.new("ab")
    scanner.begin_state(:word)
    expect(scanner.next_token).to eq([:A, "a"])
    expect(actions).to eq([:A])
  end

  %i[table direct auto firstmatch].each do |backend|
    it "preserves #{backend} examples in CLI JSON and generated artifacts" do
      source = <<~RUBY
        require "flexr"
        class TrailingExampleLexer < Flexr::Lexer
          backend :#{backend}
          option :experimental
          rule(/a/, followed_by: /b/, emit: :A)
          rule(/a/, followed_by: /b/, emit: :HIDDEN)
          rule(/b/, emit: :B)
        end
      RUBY
      Dir.mktmpdir("flexr-trailing-example-") do |directory|
        path = File.join(directory, "lexer.flexr.rb")
        output = File.join(directory, "lexer.rb")
        File.binwrite(path, source)
        stdout = StringIO.new
        stderr = StringIO.new
        expect(Flexr::CLI.run(["check", path, "--format", "json"], out: stdout, err: stderr)).to eq(0)
        expect(stderr.string).to be_empty
        note = JSON.parse(stdout.string).find { |item| item.fetch("code") == "FLEXR-W001" }.fetch("note")
        expect(note).to include('example: "ab"', "matched 1 byte, looked ahead 1 byte")

        [false, true].each do |standalone|
          generator = Flexr::Generator.new(path, output: output, options: { standalone: standalone })
          generator.generate
          expect(generator.diagnostics.find { |item| item.code == "FLEXR-W001" }.note).to eq(note)
          script = <<~RUBY
            require "json"
            load ARGV.fetch(0)
            diagnostic = TrailingExampleLexer.__flexr_compiled.diagnostics.find { |item| item.code == "FLEXR-W001" }
            puts JSON.generate([diagnostic.note, TrailingExampleLexer.new("ab").tokens])
          RUBY
          result, errors, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script, output)
          expect(status).to be_success, errors
          expect(JSON.parse(result)).to eq([note, [%w[A a], %w[B b]]])
        end
      end
    end
  end
end
