# frozen_string_literal: true

RSpec.describe "derivative DFA construction" do
  def compile(lexer, construction)
    Flexr::Automaton::Compiler.new(lexer.__flexr_spec, construction: construction).compile
  end

  def graph(dfa)
    states = [dfa.start]
    ids = { dfa.start => 0 }
    output = []
    index = 0
    while index < states.length
      state = states.fetch(index)
      transitions = Array.new(256) do |byte|
        target = dfa.transition(state, byte)
        ids[target] ||= states.push(target).length - 1 if target
      end
      output << [dfa.accepts.fetch(state).map(&:to_a), transitions]
      index += 1
    end
    expect(states.size).to eq(dfa.states)
    output
  end

  def graphs(compiled)
    [
      compiled.machines.transform_values { |machine| graph(machine.dfa) },
      compiled.rules.map { |rule| graph(rule.trailing_dfa) if rule.trailing_dfa }
    ]
  end

  def compare(lexer)
    expected = graphs(compile(lexer, :subset))
    expect(graphs(compile(lexer, :derivative))).to eq(expected)
  end

  corpus = Dir.glob("{examples,lib,site/ruby/presets,spec/fixtures}/**/*.flexr.rb", base: File.expand_path("..", __dir__))
  corpus.each do |file|
    it "matches the subset DFA for #{file}" do
      path = File.expand_path("../#{file}", __dir__)
      source = File.binread(path).gsub(/\r\n?/, "\n").force_encoding(Encoding::UTF_8)
      if file == "spec/fixtures/dynamic.flexr.rb"
        namespace = Module.new
        namespace.module_eval(source, path, 1)
        compare(namespace::DynamicFixture::Lexer)
      else
        generator = Flexr::Generator.new(path)
        compiled = %i[subset derivative].map do |construction|
          parsed = Flexr::Source::PrismReader.new(source, path: path).read
          generator.send(:compile_parsed, parsed, construction: construction)
        end
        expect(graphs(compiled.fetch(1))).to eq(graphs(compiled.fetch(0)))
      end
    end
  end

  it "reports the existing state limit error from derivative construction" do
    lexer = Class.new(Flexr::Lexer) do
      rule("abc", emit: :WORD)
    end
    lexer.__flexr_config.options[:max_dfa_states] = 2
    expect { compile(lexer, :derivative) }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E006")
    end
  end

  it "keeps acceptance order, anchor conditions, and trailing context in each lexical state" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/^[a-z]+/, followed_by: /(?:(?: )?){2}:/, emit: :LABEL, priority: 2)
      rule(/[a-z]+$/, emit: :LINE, priority: 1)
      rule([/[a-z]+/, /[A-Z]+/], emit: :WORD)
      state :nested, inclusive: false do
        rule(/(?:a*|b){1,6}c/, emit: :NESTED)
      end
    end

    compare(lexer)
  end

  it "handles Unicode fragments, absence, and the subject alphabet for pattern algebra" do
    lexer = Class.new(Flexr::Lexer) do
      option :unicode
      rule(/\p{Greek}[\p{L}\p{M}]*:/, emit: :GREEK)
      rule(/<(?~-->)(?:-->)/, emit: :COMMENT)
      non_greek = pattern(/\p{L}+/) & !pattern(/\p{Greek}+/)
      rule(pattern("[") + non_greek + pattern("]"), emit: :WORD)
      rule(pattern("{") + upto("}"), emit: :BRACED)
    end

    compare(lexer)
  end

  it "keeps escaped binary bytes and nullable subexpressions within bounded repetitions" do
    rng = Random.new(97)
    atoms = ["a", "(?:b|c)", "(?:x?)", "[ab]", "\\x00", "\\xff", "[\\x80-\\xbf]"]
    80.times do
      left, right, last = atoms.sample(3, random: rng)
      lower = rng.rand(0..3)
      suffix = rng.rand(4..6)
      sources = [
        "(?:#{left}#{right}|#{last}){#{lower},#{suffix}}!",
        "(?:#{right}|#{last}#{left})*!",
        "(?:#{last}|#{left}){#{lower},}!"
      ]
      lexer = Class.new(Flexr::Lexer) do
        encoding Encoding::BINARY
        sources.each_with_index do |source, index|
          rule(Regexp.new(source, Regexp::NOENCODING), emit: :"R#{index}")
        end
      end

      compare(lexer)
    end
  end
end
