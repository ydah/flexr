# frozen_string_literal: true

require "open3"
require "rbconfig"
require "stringio"

RSpec.describe "trailing context overlap diagnostics" do
  def lexer_class(backend = :table, &rules)
    Class.new(Flexr::Lexer) do
      backend backend
      option :experimental if backend == :firstmatch
      __flexr_config.options[:warn_level] = :all
      class_eval(&rules)
    end
  end

  def infos(lexer)
    lexer.compile!.diagnostics.select { |item| item.code == "FLEXR-I001" }
  end

  %i[table direct auto firstmatch].each do |backend|
    it "compares total lengths when body lengths differ for #{backend}" do
      lexer = lexer_class(backend) do
        rule(/a/, followed_by: /bc/, emit: :FIRST)
        rule(/ab/, followed_by: /c/, emit: :SECOND)
      end

      diagnostics = infos(lexer)
      expect(diagnostics.length).to eq(1)
      expect(diagnostics.first.message)
        .to eq("rule /ab/, followed_by: /c/ overlaps rule /a/, followed_by: /bc/ at the same total length")
      reason = backend == :firstmatch ? "first match wins" : "same total length, earlier rule wins"
      expect(diagnostics.first.note).to eq(
        %(example: "abc" selects rule /a/, followed_by: /bc/ (#{reason}; matched 1 byte, looked ahead 2 bytes))
      )
      expect(lexer.new("abc").next_token).to eq([:FIRST, "a"])
    end

    it "does not confuse equal bodies with unequal total lengths for #{backend}" do
      lexer = lexer_class(backend) do
        rule(/a/, emit: :PLAIN)
        rule(/a/, followed_by: /b/, emit: :CONTEXT)
      end

      expect(infos(lexer)).to be_empty
      token = backend == :firstmatch ? :PLAIN : :CONTEXT
      expect(lexer.new("ab").next_token).to eq([token, "a"])
    end
  end

  it "includes a winner without trailing context" do
    lexer = lexer_class do
      rule(/ab/, emit: :WORD)
      rule(/a/, followed_by: /b/, emit: :PREFIX)
    end

    expect(infos(lexer).first.note).to include('"ab" selects rule /ab/', "matched 2 bytes, looked ahead 0 bytes")
    expect(lexer.new("ab").tokens).to eq([[:WORD, "ab"]])
  end

  it "checks trailing matches before naming the winner" do
    lexer = lexer_class do
      rule(/a/, followed_by: /c/, emit: :WRONG)
      rule(/a/, followed_by: /b/, emit: :FIRST)
      rule(/a/, followed_by: /b/, emit: :SECOND)
    end

    expect(infos(lexer).map(&:note)).to eq([
      'example: "ab" selects rule /a/, followed_by: /b/ (same total length, earlier rule wins; matched 1 byte, looked ahead 1 byte)'
    ])
    expect(lexer.new("ab").next_token).to eq([:FIRST, "a"])
  end

  it "does not report a later tie when firstmatch selects a shorter prefix" do
    lexer = lexer_class(:firstmatch) do
      rule(/a/, emit: :PREFIX)
      rule(/ab/, followed_by: /c/, emit: :FIRST_LONG)
      rule(/ab/, followed_by: /c/, emit: :SECOND_LONG)
    end

    expect(infos(lexer)).to be_empty
    expect(lexer.new("abc").next_token).to eq([:PREFIX, "a"])
  end

  it "checks native regexp alternative order before comparing totals" do
    lexer = lexer_class(:firstmatch) do
      rule(/a|ab/, followed_by: /b|c/, emit: :SHORT)
      rule(/ab/, followed_by: /c/, emit: :LONG)
    end

    expect(infos(lexer)).to be_empty
    expect(lexer.new("abc").next_token).to eq([:SHORT, "a"])
  end

  it "keeps the longest body for equal-total splits within one rule" do
    lexer = lexer_class do
      rule(/a+/, followed_by: /a+/, emit: :FIRST)
      rule(/aaa/, followed_by: /a/, emit: :SECOND)
    end

    expect(infos(lexer).first.note).to include('"aaaa"', "matched 3 bytes, looked ahead 1 byte")
    expect(lexer.new("aaaa").next_token).to eq([:FIRST, "aaa"])
  end

  it "validates body and trailing end anchors" do
    lexer = lexer_class do
      rule(/a$/, followed_by: /b/, emit: :WRONG)
      rule(/a/, followed_by: /b$/, emit: :FIRST)
      rule(/a/, followed_by: /b$/, emit: :SECOND)
    end

    expect(infos(lexer).length).to eq(1)
    expect(infos(lexer).first.note).to include('"ab" selects rule /a/, followed_by: /b$/')
    expect(lexer.new("ab").next_token).to eq([:FIRST, "a"])
  end

  it "uses Unicode byte lengths and rejects a body that splits a character" do
    lexer = lexer_class do
      rule(/é/, followed_by: /日/, emit: :FIRST)
      rule(/é日/, emit: :SECOND)
    end
    expect(infos(lexer).first.note).to include('"é日"', "matched 2 bytes, looked ahead 3 bytes")
    expect(lexer.new("é日").next_token).to eq([:FIRST, "é"])

    split = lexer_class do
      rule(/\xC3/n, followed_by: /\xA9/n, emit: :BYTE)
      rule(/é/, emit: :CHAR)
    end
    expect(infos(split)).to be_empty
  end

  it "escapes binary trailing input in diagnostic JSON" do
    lexer = lexer_class do
      encoding Encoding::BINARY
      rule(/a/, followed_by: /\xFF/n, emit: :FIRST)
      rule(/a\xFF/n, emit: :SECOND)
    end

    diagnostic = infos(lexer).first
    expect(diagnostic.note).to include('"a\xFF"', "matched 1 byte, looked ahead 1 byte")
    expect(JSON.parse(JSON.generate(diagnostic.to_h)).fetch("note")).to eq(diagnostic.note)
    expect(lexer.new("a\xff".b).next_token).to eq([:FIRST, "a"])
  end

  it "omits a tie if the runtime cannot compile a trailing matcher" do
    lexer = lexer_class do
      rule(/a/, followed_by: /b*/, emit: :FIRST)
      rule(/a/, followed_by: /b*/, emit: :SECOND)
    end
    expect(infos(lexer)).to be_empty
  end

  it "checks empty bodies with nonempty trailing input without running actions" do
    actions = []
    lexer = lexer_class do
      option :allow_empty_match
      rule(//, followed_by: /b/) do
        actions << :EMPTY
        emit :EMPTY
      end
      rule(/b/, emit: :SECOND)
    end

    expect(infos(lexer).first.note).to include('"b"', "matched 0 bytes, looked ahead 1 byte")
    expect(actions).to be_empty
    expect(lexer.new("b").next_token).to eq([:EMPTY, ""])
    expect(actions).to eq([:EMPTY])
  end

  it "compares only active rules and identifies the state" do
    lexer = lexer_class do
      rule(/abc/, emit: :INITIAL)
      state :word do
        rule(/a/, followed_by: /bc/, emit: :FIRST)
        rule(/ab/, followed_by: /c/, emit: :SECOND)
      end
    end

    expect(infos(lexer).length).to eq(1)
    expect(infos(lexer).first.note).to include("in state :word", "matched 1 byte, looked ahead 2 bytes")
    scanner = lexer.new("abc")
    scanner.begin_state(:word)
    expect(scanner.next_token).to eq([:FIRST, "a"])
  end

  %i[table direct auto firstmatch].each do |backend|
    it "preserves #{backend} reports in CLI JSON and both artifact modes" do
      source = <<~RUBY
        require "flexr"
        class TrailingOverlapLexer < Flexr::Lexer
          backend :#{backend}
          option :experimental
          rule(/a/, followed_by: /bc/, emit: :FIRST)
          rule(/ab/, followed_by: /c/, emit: :SECOND)
        end
      RUBY
      Dir.mktmpdir("flexr-trailing-overlap-") do |directory|
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
            expect(cli_info.fetch("severity")).to eq("info")
            start, finish = cli_info.fetch("location")
            expect(source.byteslice(start...finish)).to eq("rule(/ab/, followed_by: /c/, emit: :SECOND)")
          else
            expect(records).to be_empty
          end
        end
        [false, true].each do |standalone|
          Flexr::Generator.new(path, output: output, options: { warn_level: :all, standalone: standalone }).generate
          script = <<~RUBY
            require "json"
            load ARGV.fetch(0)
            info = TrailingOverlapLexer.__flexr_compiled.diagnostics.find { |item| item.code == "FLEXR-I001" }
            puts JSON.generate([info.to_h, info.warning?, TrailingOverlapLexer.new("abc").next_token])
          RUBY
          result, errors, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script, output)
          expect(status).to be_success, errors
          expect(JSON.parse(result)).to eq([cli_info, false, %w[FIRST a]])
        end
      end
    end
  end
end
