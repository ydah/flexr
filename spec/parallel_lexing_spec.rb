# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "parallel lexing" do
  parallel_ruby = RUBY_ENGINE == "ruby" && Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0.6")

  before(:example, :requires_ractors) do
    skip "requires CRuby 4.0.6 or newer" unless parallel_ruby
  end

  def count_coordinator_scans(&)
    count = 0
    trace = TracePoint.new(:call) do |event|
      count += 1 if event.method_id == :next_token && event.self.is_a?(Flexr::Lexer)
    end
    tokens = trace.enable(target_thread: Thread.current, &)
    [tokens, count]
  end

  it "returns the serial token stream from multiple real Ractors", :requires_ractors do
    lexer = Class.new(Flexr::Lexer) do
      rule(/[a-z]+/, emit: :WORD)
      rule("\n", emit: :NEWLINE)
      rule(/ +/, skip: true)
    end
    input = "alpha beta\n" * 12
    expected = lexer.new(input).tokens

    expect(Ractor).to receive(:new).at_least(:twice).and_call_original
    actual, coordinator_scans = count_coordinator_scans { lexer.parallel_tokens(input, workers: 3, min_bytes: 0) }

    expect(actual).to eq(expected)
    expect(coordinator_scans).to be < expected.length
  end

  it "relexes only the mismatched section of a structured UTF-8 token stream", :requires_ractors do
    lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/éééé/, emit: :QUAD)
      rule("é", emit: :SINGLE)
      rule("!", emit: :MARK)
      rule("\n", emit: :NEWLINE)
    end
    input = "#{'é' * 2350}!\n#{'éééé!' * 811}!!!!!"
    expected = lexer.new(input, filename: "blocks.txt").tokens

    expect(Ractor).to receive(:new).at_least(:twice).and_call_original
    actual, coordinator_scans = count_coordinator_scans do
      lexer.parallel_tokens(input, workers: 3, min_bytes: 0, filename: "blocks.txt")
    end

    expect(actual).to eq(expected)
    expect(coordinator_scans).to be_between(1, expected.length - 1)
  end

  it "uses a serial scan below the input threshold" do
    lexer = Class.new(Flexr::Lexer) { rule(/[a-z]+/, emit: :WORD) }

    expect(Ractor).not_to receive(:new)
    expect(lexer.parallel_tokens("word")).to eq([[:WORD, "word"]])
  end

  ["3.4.13", "4.0.5"].each do |version|
    it "uses the serial path on CRuby #{version}" do
      stub_const("RUBY_VERSION", version)
      lexer = Class.new(Flexr::Lexer) { rule(/./, emit: :LETTER) }
      input = "word" * 12

      expect(Ractor).not_to receive(:new)
      expect(lexer.parallel_tokens(input, workers: 3, min_bytes: 0)).to eq(lexer.new(input).tokens)
    end
  end

  it "executes opaque actions once without starting Ractors" do
    calls = []
    lexer = Class.new(Flexr::Lexer) do
      rule(/./) do
        calls << text
        emit(:CHARACTER, calls.length)
      end
    end

    expect(Ractor).not_to receive(:new)
    expect(lexer.parallel_tokens("abcdef", workers: 3, min_bytes: 0)).to eq((1..6).map { |n| [:CHARACTER, n] })
    expect(calls).to eq(%w[a b c d e f])
  end

  it "runs a lexer with an EOF action serially and emits EOF once" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/./, emit: :CHARACTER)
      on_eof { emit(:END) }
    end

    expect(Ractor).not_to receive(:new)
    expect(lexer.parallel_tokens("abc", workers: 3, min_bytes: 0)).to eq([[:CHARACTER, "a"], [:CHARACTER, "b"],
                                                                        [:CHARACTER, "c"], [:END, ""]])
  end

  it "raises the serial lexical error with absolute source coordinates", :requires_ractors do
    lexer = Class.new(Flexr::Lexer) do
      rule(/[a-z]+/, emit: :WORD)
      rule("\n", skip: true)
    end
    input = "#{"word\n" * 12}?"

    expect(Ractor).to receive(:new).at_least(:twice).and_call_original
    expect do
      lexer.parallel_tokens(input, workers: 3, min_bytes: 0, filename: "invalid.txt")
    end.to raise_error(Flexr::LexError) { |error|
      expect([error.byte_pos, error.line, error.filename]).to eq([60, 13, "invalid.txt"])
    }
  end

  [[:table, false], [:direct, true]].each do |backend, standalone|
    it "matches a full scan in generated #{backend} mode with standalone=#{standalone}" do
      source = <<~'RUBY'
        class ParallelParityLexer < Flexr::Lexer
          token_kind :struct
          rule(/^é+/, emit: :LINE_START)
          rule(/é+/, emit: :WORD)
          rule("!", emit: :MARK)
          rule(/\r?\n/, skip: true)
        end
      RUBY
      runner = <<~'RUBY'
        load ARGV.fetch(0)
        started = 0
        launch = Ractor.method(:new)
        Ractor.define_singleton_method(:new) do |*args, **kwargs, &block|
          started += 1
          launch.call(*args, **kwargs, &block)
        end
        input = "éé!é\r\n" * 30 + "é!é"
        expected = ParallelParityLexer.new(input, filename: "lines.txt").tokens
        actual = ParallelParityLexer.parallel_tokens(input, workers: 3, min_bytes: 0, filename: "lines.txt")
        abort "parallel tokens differ" unless actual == expected
        expected_workers = Integer(ARGV.fetch(1))
        abort "expected #{expected_workers} Ractors, started #{started}" unless started == expected_workers
      RUBY

      Dir.mktmpdir("flexr-parallel-") do |directory|
        specification = File.join(directory, "parallel.flexr.rb")
        artifact = File.join(directory, "parallel.rb")
        File.binwrite(specification, source)
        Flexr::Generator.new(specification, output: artifact, options: {backend: backend, standalone: standalone}).generate
        command = [RbConfig.ruby, *(standalone ? ["--disable-gems"] : %w[-Ilib -rflexr])]
        environment = standalone ? {"RUBYOPT" => nil, "RUBYLIB" => nil} : {}
        _output, error, status = Open3.capture3(environment, *command, "-e", runner, artifact, parallel_ruby ? "3" : "0")

        expect(status).to be_success, error
      end
    end
  end
end
