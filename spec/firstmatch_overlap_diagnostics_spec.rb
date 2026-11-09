# frozen_string_literal: true

require "open3"
require "rbconfig"
require "stringio"

RSpec.describe "firstmatch overlap diagnostics" do
  def lexer_class(&rules)
    Class.new(Flexr::Lexer) do
      backend :firstmatch
      option :experimental
      __flexr_config.options[:warn_level] = :all
      class_eval(&rules)
    end
  end

  def infos(lexer)
    lexer.compile!.diagnostics.select { |item| item.code == "FLEXR-I001" }
  end

  it "reports equal native matches with their actual byte count" do
    lexer = lexer_class do
      rule(/ab/i, emit: :FIRST)
      rule(/ab/i, emit: :SECOND)
    end

    expect(infos(lexer).map(&:note)).to eq([
      'example: "AB" selects rule /ab/i (first match wins, matched 2 bytes)'
    ])
    expect(lexer.new("AB").next_token).to eq([:FIRST, "AB"])
  end

  it "rejects DFA ties when regexp alternative order gives a shorter match" do
    lexer = lexer_class do
      rule(/a|ab/i, emit: :SHORT)
      rule(/ab/i, emit: :LONG)
    end

    expect(infos(lexer)).to be_empty
    expect(lexer.new("AB").next_token).to eq([:SHORT, "A"])
  end

  it "does not report a later tie when an earlier short prefix wins" do
    lexer = lexer_class do
      rule(/a/, emit: :SHORT)
      rule(/ab/, emit: :FIRST_LONG)
      rule(/ab/, emit: :SECOND_LONG)
    end

    expect(infos(lexer)).to be_empty
    expect(lexer.new("ab").next_token).to eq([:SHORT, "a"])
  end

  it "chooses the longest matching pattern within each rule" do
    lexer = lexer_class do
      rule(%w[a ab], emit: :FIRST)
      rule(/ab/, emit: :SECOND)
    end

    expect(infos(lexer).first.note)
      .to eq('example: "ab" selects rule ["a", "ab"] (first match wins, matched 2 bytes)')
    expect(lexer.new("ab").tokens).to eq([[:FIRST, "ab"]])
  end

  it "checks reference-regexp end anchors before naming the winner" do
    lexer = lexer_class do
      rule(/(?:\p{L}|\p{L}{2})$/, emit: :ANCHORED)
      rule(/ab/, emit: :FIRST)
      rule(/ab/, emit: :SECOND)
    end

    expect(infos(lexer).map(&:note)).to eq([
      'example: "ab" selects rule /ab/ (first match wins, matched 2 bytes)'
    ])
    expect(lexer.new("ab").tokens).to eq([[:FIRST, "ab"]])
  end

  it "uses Unicode reference matching and counts bytes" do
    lexer = lexer_class do
      option :unicode
      rule(/\w/, emit: :FIRST)
      rule(/é/, emit: :SECOND)
    end

    expect(infos(lexer).first.note).to eq('example: "é" selects rule /\w/ (first match wins, matched 2 bytes)')
    expect(lexer.new("é").tokens).to eq([[:FIRST, "é"]])
  end

  it "uses active rules in the named state" do
    lexer = lexer_class do
      rule(/a/, emit: :INITIAL)
      state :word do
        rule(/ab/, emit: :FIRST)
        rule(/ab/, emit: :SECOND)
      end
    end

    expect(infos(lexer).first.note)
      .to eq('example: "ab" selects rule /ab/ in state :word (first match wins, matched 2 bytes)')
    scanner = lexer.new("ab")
    scanner.begin_state(:word)
    expect(scanner.tokens).to eq([[:FIRST, "ab"]])
  end

  it "handles binary input and omits incompatible UTF-8 matches" do
    binary = lexer_class do
      encoding Encoding::BINARY
      rule(/\xFF/n, emit: :FIRST)
      rule(/\xFF/n, emit: :SECOND)
    end
    expect(infos(binary).first.note).to include('example: "\xFF"', "matched 1 byte")
    expect(binary.new("\xff".b).tokens).to eq([[:FIRST, "\xff".b]])

    incompatible = lexer_class do
      rule(/\xC3/n, emit: :BYTE)
      rule(/é/, emit: :FIRST)
      rule(/é/, emit: :SECOND)
    end
    expect(infos(incompatible)).to be_empty
  end

  it "reports zero-byte ties without executing actions during compilation" do
    actions = []
    lexer = lexer_class do
      option :allow_empty_match
      rule(/|a/) do
        actions << :EMPTY
        emit :EMPTY
      end
      rule(/|a/, emit: :SECOND)
    end
    expect(infos(lexer).first.note).to eq('example: "a" selects rule /|a/ (first match wins, matched 0 bytes)')
    expect(actions).to be_empty
    expect(lexer.new("a").next_token).to eq([:EMPTY, ""])
    expect(actions).to eq([:EMPTY])
  end

  it "preserves the verified example in CLI JSON and generated artifacts" do
    source = <<~RUBY
      require "flexr"
      class FirstmatchOverlapLexer < Flexr::Lexer
        backend :firstmatch
        option :experimental
        rule(%w[a c], emit: :FIRST)
        rule(%w[b c], emit: :SECOND)
      end
    RUBY
    Dir.mktmpdir("flexr-firstmatch-overlap-") do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      File.binwrite(path, source)
      cli_info = nil
      %w[default none all].each do |level|
        stdout = StringIO.new
        stderr = StringIO.new
        expect(Flexr::CLI.run(["check", path, "--warn", level, "--format", "json"], out: stdout, err: stderr)).to eq(0)
        expect(stderr.string).to be_empty
        records = JSON.parse(stdout.string).select { |item| item.fetch("code") == "FLEXR-I001" }
        if level == "all"
          expect(records.length).to eq(1)
          cli_info = records.first
          expect(cli_info.fetch("note")).to eq('example: "c" selects rule ["a", "c"] (first match wins, matched 1 byte)')
          expect(cli_info.fetch("severity")).to eq("info")
        else
          expect(records).to be_empty
        end
      end
      [false, true].each do |standalone|
        generator = Flexr::Generator.new(path, output: output, options: { warn_level: :all, standalone: standalone })
        generator.generate
        script = <<~RUBY
          require "json"
          load ARGV.fetch(0)
          info = FirstmatchOverlapLexer.__flexr_compiled.diagnostics.find { |item| item.code == "FLEXR-I001" }
          puts JSON.generate([info.to_h, info.warning?, FirstmatchOverlapLexer.new("abc").tokens])
        RUBY
        result, errors, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script, output)
        expect(status).to be_success, errors
        expect(JSON.parse(result)).to eq([cli_info, false, [%w[FIRST a], %w[SECOND b], %w[FIRST c]]])
      end
    end
  end
end
