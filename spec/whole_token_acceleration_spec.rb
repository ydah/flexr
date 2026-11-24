# frozen_string_literal: true

require "stringio"
require "open3"
require "rbconfig"

RSpec.describe "whole-token acceleration" do
  def lexer_class(accel = :strscan)
    Class.new(Flexr::Lexer) do
      self.accel(accel)
      rule(/a|ab/) { emit :WORD }
      rule(/x[0-9]+;/) { emit :NUMBER }
      rule(/./m) { emit :OTHER }
    end
  end

  it "proves complete subgraphs without adopting Ruby's alternation priority" do
    lexer = Class.new(Flexr::Lexer) do
      accel :strscan
      rule(/a|ab/) { emit :WORD }
      rule(/x[0-9]+;/) { emit :NUMBER }
    end
    machine = lexer.compile!.machines.fetch(:initial)
    plans = machine.whole_tokens
    expect(plans.fetch("a".ord).rule_index).to eq(0)
    expect(plans.fetch("x".ord).rule_index).to eq(1)
    expect(lexer.new("abx123;").tokens).to eq([[:WORD, "ab"], [:NUMBER, "x123;"]])
    expect(/a|ab/.match("ab")[0]).to eq("a")
  end

  it "declines ambiguous rule winners, multi-state cycles, and non-ASCII paths" do
    [
      [/a/, /ab/],
      [/(?:ab)+/],
      [/a{40}/],
      [/x[^;]+;/],
      [/^a/],
      [/a$/]
    ].each do |patterns|
      lexer = Class.new(Flexr::Lexer)
      lexer.accel(:strscan)
      patterns.each { |pattern| lexer.rule(pattern, skip: true) }
      plans = lexer.compile!.machines.fetch(:initial).whole_tokens
      expect(plans.nil? || plans.compact.empty?).to be(true), patterns.inspect
    end
    expect(lexer_class(:auto).compile!.machines.fetch(:initial).whole_tokens).to be_nil
  end

  it "uses one native scan for a complete token" do
    lexer = Class.new(Flexr::Lexer) do
      accel :strscan
      rule(/x[0-9]+;/) { emit :NUMBER }
    end
    plan = lexer.compile!.machines.fetch(:initial).whole_tokens.fetch("x".ord)
    expect_any_instance_of(StringScanner).to receive(:skip).with(plan.regexp).and_call_original
    expect(lexer.new("x123456789;").tokens).to eq([[:NUMBER, "x123456789;"]])
  end

  it "agrees with exhaustive DFA prefix selection on deterministic inputs" do
    random = Random.new(42)
    inputs = %w[a ab aaab abbb x0; x001; x1; x123;] +
      Array.new(500) { Array.new(random.rand(1..8)) { %w[a b x 0 1 ; é].sample(random: random) }.join }
    [/a|ab/, /a*b+/, /x[01]+;/, /ab?b*/, /x(?:0|1[01]*);/].each do |pattern|
      lexer = Class.new(Flexr::Lexer) do
        accel :strscan
        rule(pattern, skip: true)
      end
      machine = lexer.compile!.machines.fetch(:initial)
      inputs.each do |input|
        plan = machine.whole_tokens&.[](input.getbyte(0))
        next unless plan

        expected = input.bytesize.downto(1).find { |length| machine.dfa.accept?(input.byteslice(0, length)) }
        actual = StringScanner.new(input).skip(plan.regexp)
        expect(actual).to eq(expected), "#{pattern.inspect} on #{input.inspect}"
      end
    end
  end

  it "preserves limits, cancellation, streaming and mutable input" do
    lexer = lexer_class
    ["abx12;?".dup, "abx12;?", StringIO.new("abx12;?")].each do |input|
      expect(lexer.new(input, chunk_size: 1, freeze_input: false).tokens).to eq(lexer_class(:none).new("abx12;?").tokens)
    end
    expect { lexer.new("ab", max_token_size: 1).tokens }.to raise_error(Flexr::Runtime::TokenTooLargeError)
    expect { lexer.new("ab", max_steps: 1).tokens }.to raise_error(Flexr::Runtime::StepLimitError)
    expect { lexer.new("ab", cancellation: -> { true }).tokens }.to raise_error(Flexr::Runtime::CancelledError)
    invalid = "ab\xff".dup.force_encoding(Encoding::UTF_8).freeze
    instance = lexer.new(invalid)
    expect(instance.next_token).to eq([:WORD, "ab"])
    expect { instance.next_token }.to raise_error(Flexr::LexError)
  end

  it "keeps DFA traversal available without StringScanner" do
    lexer = lexer_class
    lexer.compile!
    hide_const("StringScanner")
    expect(lexer.new("abx12;?").tokens).to eq(lexer_class(:none).new("abx12;?").tokens)
  end

  it "preserves generated scanner results with every table representation" do
    Dir.mktmpdir do |directory|
      spec = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      File.write(spec, <<~RUBY)
        class WholeTokenFixture < Flexr::Lexer
          accel :strscan
          rule(/a|ab/) { emit :WORD }
          rule(/x[0-9]+;/) { emit :NUMBER }
          rule(/./m) { emit :OTHER }
        end
      RUBY
      expected = lexer_class(:none).new("abx123;ax;").tokens
      [{}, { backend: :direct }, { table_compression: :rows }, { table_compression: :full },
       { table_format: :packed }].each do |options|
        Flexr::Generator.new(spec, output: output, options: options).generate
        load output
        ["abx123;ax;", StringIO.new("abx123;ax;")].each do |input|
          expect(WholeTokenFixture.new(input, chunk_size: 1).tokens).to eq(expected)
        end
        Object.send(:remove_const, :WholeTokenFixture)
      end
      Flexr::Generator.new(spec, output: output, options: { standalone: true }).generate
      script = 'load ARGV.fetch(0); puts JSON.generate(WholeTokenFixture.new("abx123;ax;".freeze).tokens)'
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, output)
      expect(status).to be_success, stderr
      expect(JSON.parse(stdout)).to eq(JSON.parse(JSON.generate(expected)))

      Flexr::Generator.new(spec, output: output).generate
      legacy_script = <<~RUBY
        require "flexr"
        Flexr::Automaton::Machine.send(:undef_method, :whole_tokens)
        Flexr::Runtime.send(:remove_method, :__flexr_whole_token_match)
        load ARGV.fetch(0)
        puts JSON.generate(WholeTokenFixture.new("abx123;ax;".freeze).tokens)
      RUBY
      runner = File.join(directory, "legacy.rb")
      File.write(runner, legacy_script)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", runner, output)
      expect(status).to be_success, stderr
      expect(JSON.parse(stdout)).to eq(JSON.parse(JSON.generate(expected)))
    ensure
      Object.send(:remove_const, :WholeTokenFixture) if Object.const_defined?(:WholeTokenFixture, false)
    end
  end
end
