# frozen_string_literal: true

require "flexr/testing"
require "open3"
require "rbconfig"
require "stringio"

RSpec.describe "lexer transition coverage" do
  it "counts speculative and repeated transitions while returning normal tokens" do
    lexer = Class.new(Flexr::Lexer) do
      accel :strscan
      rule(/a/, emit: :A)
      rule(/ab+c/, emit: :LONG)
      rule(/b+z/, emit: :REST)
    end
    coverage = Flexr::Testing::Coverage.new(lexer)
    tokens = coverage.lexer(StringIO.new("abbbz"), chunk_size: 1, retain_input: false).tokens
    expect(tokens).to eq([[:A, "a"], [:REST, "bbbz"]])

    dfa = lexer.compile!.machines.fetch(:initial).dfa
    a_state = dfa.transition(dfa.start, "a".ord)
    b_state = dfa.transition(a_state, "b".ord)
    report = coverage.report
    expect(report.fetch(:transitions)).to include(hash_including(
      from: b_state, byte_class: dfa.ec.fetch("b".ord), to: b_state, hits: 2
    ))
    cold = report.fetch(:uncovered).find { |edge| edge[:from] == b_state && edge[:byte_class] == dfa.ec.fetch("c".ord) }
    expect(cold).to include(state: :initial, hits: 0, example: {input: "abc", offset: 0})
    expect(coverage.lexer(cold.fetch(:example).fetch(:input)).tokens).to eq([[:LONG, "abc"]])
    expect(coverage.report.fetch(:covered)).to eq(coverage.report.fetch(:total))
  end

  it "suggests a shortest source and scan offset for a contextual start" do
    lexer = Class.new(Flexr::Lexer) do
      state(:inside, inclusive: false) { rule(/(?<=é)b/, emit: :LETTER) }
    end
    coverage = Flexr::Testing::Coverage.new(lexer)
    cold = coverage.report.fetch(:uncovered).find { |edge| edge[:state] == :inside && edge[:example] }
    expect(cold.fetch(:example)).to eq(input: "éb", offset: 2)

    scanner = coverage.lexer(cold.fetch(:example).fetch(:input))
    scanner.begin_state(cold.fetch(:state))
    scanner.seek(cold.fetch(:example).fetch(:offset))
    expect(scanner.next_token).to eq([:LETTER, "b"])
    expect(coverage.report.fetch(:transitions)).to include(hash_including(state: :inside, hits: 1))
  end

  it "records edges before an unmatched-input error" do
    lexer = Class.new(Flexr::Lexer) { rule("ab", emit: :WORD) }
    coverage = Flexr::Testing::Coverage.new(lexer)
    expect { coverage.lexer("a!").tokens }.to raise_error(Flexr::LexError)
    expect(coverage.report).to include(covered: 1, total: 2)
  end

  it "preserves fast-path matching of a raw byte rule in a UTF-8 lexer" do
    lexer = Class.new(Flexr::Lexer) { rule(/\xc3/n, emit: :BYTE) }
    input = "é"
    ordinary_tokens = lexer.new(input, error_mode: :token).tokens
    expect(ordinary_tokens.first.first).to eq(:BYTE)

    coverage = Flexr::Testing::Coverage.new(lexer)
    expect(coverage.lexer(input, error_mode: :token).tokens).to eq(ordinary_tokens)
    expect(coverage.report).to include(covered: 1, total: 1)
  end

  it "keeps the recorder through input pushes and resumes in distinct lexical states" do
    lexer = Class.new(Flexr::Lexer) do
      option :input_stack
      rule("!") do
        begin_state(:nested)
        push_input(StringIO.new("b"))
        skip
      end
      rule("b", emit: :CHILD)
      state(:nested, inclusive: false) { rule("a", emit: :RESUMED) }
    end
    coverage = Flexr::Testing::Coverage.new(lexer)
    expect(coverage.lexer("!a", chunk_size: 1).tokens).to eq([[:CHILD, "b"], [:RESUMED, "a"]])
    expect(coverage.report).to include(covered: 3, total: 3)
    expect(coverage.report.fetch(:transitions).group_by { |edge| edge[:state] }.transform_values(&:size))
      .to eq(initial: 2, nested: 1)
  end

  it "preserves generated actions while walking the direct backend's DFA" do
    Dir.mktmpdir do |directory|
      source = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      File.write(source, <<~RUBY)
        class CoverageGeneratedLexer < Flexr::Lexer
          backend :direct
          rule(/[a-z]+/) { emit :WORD, text.upcase }
        end
      RUBY
      Flexr::Generator.new(source, output: output).generate
      load output
      coverage = Flexr::Testing::Coverage.new(CoverageGeneratedLexer)
      expect(coverage.lexer("abc").tokens).to eq(CoverageGeneratedLexer.new("abc").tokens)
      expect(coverage.report.fetch(:transitions).sum { |edge| edge[:hits] }).to eq(3)
    ensure
      Object.send(:remove_const, :CoverageGeneratedLexer) if Object.const_defined?(:CoverageGeneratedLexer, false)
    end
  end

  it "reports invalid UTF-8-only edges and preserves raw binary suggestions" do
    utf8 = Class.new(Flexr::Lexer) { rule(/\xff/n, emit: :BYTE) }
    binary = Class.new(Flexr::Lexer) do
      encoding Encoding::BINARY
      rule(/\xff/n, emit: :BYTE)
    end
    expect(Flexr::Testing::Coverage.new(utf8).report.fetch(:uncovered))
      .to contain_exactly(hash_including(reason: :no_valid_input))
    expect(Flexr::Testing::Coverage.new(binary).report.fetch(:uncovered))
      .to contain_exactly(hash_including(example: {input: "\xff".b, offset: 0}))
  end

  it "collects and replays a witness with standalone output loaded first" do
    Dir.mktmpdir do |directory|
      source = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      File.write(source, <<~RUBY)
        class CoverageStandaloneLexer < Flexr::Lexer
          backend :direct
          rule(/(?<=é)b/) { emit :LETTER, text.upcase }
        end
      RUBY
      Flexr::Generator.new(source, output: output, options: {standalone: true}).generate
      script = <<~RUBY
        load ARGV.fetch(0)
        require "flexr/testing"
        coverage = Flexr::Testing::Coverage.new(CoverageStandaloneLexer)
        example = coverage.report.fetch(:uncovered).first.fetch(:example)
        abort example.inspect unless example == {input: "éb", offset: 2}
        scanner = coverage.lexer(example.fetch(:input)).seek(example.fetch(:offset))
        abort "wrong token" unless scanner.next_token == [:LETTER, "B"]
        abort "edge did not register" unless coverage.report.fetch(:covered) == 1
      RUBY
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script, output)
      expect(status).to be_success, "#{stdout}\n#{stderr}"
    end
  end

  it "reports the absence of body DFA coverage for firstmatch" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule("a", emit: :A)
    end
    expect { Flexr::Testing::Coverage.new(lexer) }.to raise_error(ArgumentError, /firstmatch/)
  end
end
