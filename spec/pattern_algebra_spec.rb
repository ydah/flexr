# frozen_string_literal: true

require "stringio"

RSpec.describe "pattern algebra" do
  let(:dsl) { Class.new(Flexr::Lexer) }

  it "copies literal input and builds immutable, Ractor-shareable values" do
    literal = +"alpha"
    value = dsl.pattern(literal, [/b[ae]/, ["gamma"]])
    literal.replace("changed")
    dfa = Flexr.compile_pattern(value)

    expect(value).to be_frozen
    expect(Ractor.shareable?(value)).to be(true)
    expect(%w[alpha ba gamma].all? { |input| dfa.accept?(input) }).to be(true)
    expect(dfa.accept?("changed")).to be(false)
  end

  it "uses union, concatenation, intersection, difference and complement as DFA languages" do
    identifier = dsl.pattern(/[a-z_][a-z0-9_]*/)
    short = dsl.pattern(/.{1,8}/m)
    identifier = (identifier & short) - %w[if while]
    identifier &= !dsl.pattern(/.*__.*/m)
    fragment = dsl.pattern("#") + identifier
    dfa = Flexr.compile_pattern(fragment | ".")

    expect(%w[#a #a_1 #abcdefgh .].all? { |input| dfa.accept?(input) }).to be(true)
    expect(%w[#if #while #a__b #abcdefghi ..].any? { |input| dfa.accept?(input) }).to be(false)
  end

  it "limits complement to the subject alphabet" do
    value = dsl.pattern("x") + !dsl.pattern("é")
    dfa = Flexr.compile_pattern(value)

    expect(%W[x xあ xéé x\n].all? { |input| dfa.accept?(input) }).to be(true)
    expect(dfa.accept?("xé")).to be(false)
    expect(dfa.accept?("x\xED\xA0\x80".b)).to be(false)
  end

  it "ends upto at the first delimiter even when the delimiter overlaps itself" do
    value = dsl.pattern("<") + dsl.upto("aba")
    dfa = Flexr.compile_pattern(value)

    expect(dfa.accept?("<é\naba")).to be(true)
    expect(dfa.accept?("<ababa")).to be(false)
    expect(dfa.accept?("<ab")).to be(false)
  end

  it "requires upto matches to end on a scalar boundary in UTF-8" do
    value = dsl.upto(/\xC3/n)
    expect { Flexr.compile_pattern(value) }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E029")
    end
    binary = Flexr.compile_pattern(value, encoding: Encoding::BINARY)
    expect(binary.accept?("a\xC3".b)).to be(true)
  end

  it "diagnoses empty intersections, full subtractions, and nullable rules" do
    left = dsl.pattern("a")
    [left & "b", left - /[ab]/].each do |value|
      expect { Flexr.compile_pattern(value) }.to raise_error(Flexr::CompileError) do |error|
        expect(error.diagnostic.code).to eq("FLEXR-E029")
        expect(error.diagnostic.message).to include("empty")
      end
    end
    expect { Flexr.compile_pattern(!left) }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E005")
    end
  end

  it "shows a concrete witness when a subtraction removes nothing" do
    dsl.rule(dsl.pattern(/[ab]/) - "cat", emit: :LETTER)
    warning = dsl.compile!.diagnostics.find { |diagnostic| diagnostic.code == "FLEXR-W021" }

    expect(warning.message).to include("removes no")
    expect(warning.note).to include('"cat"')
  end

  it "reports measured state growth and attributes it to the operation" do
    value = dsl.pattern(/(?:aaa)+/) & dsl.pattern(/(?:aaaaaaa)+/)
    dsl.rule(value, emit: :PERIOD)
    compiled = dsl.compile!
    warning = compiled.diagnostics.find { |diagnostic| diagnostic.code == "FLEXR-W011" }
    operations = compiled.stats.fetch(:initial).fetch(:pattern_operations)

    expect(warning.message).to include("intersection")
    expect(operations).to include(a_hash_including(operation: :intersection, result_states: 22))
    expect { Flexr.compile_pattern(value, options: { max_dfa_states: 16 }) }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E006")
      expect(error.diagnostic.message).to include("&")
    end
  end

  it "rejects firstmatch bodies that would otherwise use Ruby regexp selection" do
    dsl.backend :firstmatch
    dsl.rule(dsl.pattern("x") - "y", emit: :X)

    expect { dsl.compile! }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E014")
      expect(error.diagnostic.help).to include("backend :table")
    end
  end

  it "keeps pattern values on the DFA scanner with explicit whole-token acceleration" do
    dsl.accel :strscan
    dsl.rule(dsl.pattern("ab"), emit: :AB)

    expect(dsl.compile!.machines.fetch(:initial).whole_tokens).to be_nil
    expect(dsl.new("ab").tokens).to eq([[:AB, "ab"]])
  end

  it "resolves constants statically and shows their source names in explain and DOT" do
    Dir.mktmpdir("flexr-pattern-cli") do |dir|
      path = File.join(dir, "lexer.flexr.rb")
      File.write(path, <<~RUBY)
        raise "generation executed the specification"
        class NamedPatternLexer < Flexr::Lexer
          IDENT = pattern(/[a-z]+/)
          KEYWORD = pattern(%w[if end])
          rule(IDENT - KEYWORD, emit: :IDENT)
        end
      RUBY

      expect { Flexr::Generator.new(path).generate }.not_to raise_error
      %w[explain dot].each do |command|
        output = StringIO.new
        errors = StringIO.new
        status = Flexr::CLI.run([command, path], out: output, err: errors)
        expect(status).to eq(0), errors.string
        expect(output.string).to include("IDENT - KEYWORD")
      end
    end
  end

  it "locates an empty named expression and reports samples for its operands" do
    Dir.mktmpdir("flexr-pattern-diagnostic") do |dir|
      path = File.join(dir, "lexer.flexr.rb")
      statement = "rule(LEFT & RIGHT, emit: :DEAD)"
      source = <<~RUBY
        # é
        class NamedPatternLexer < Flexr::Lexer
          LEFT = pattern("a")
          RIGHT = pattern("b")
          #{statement}
        end
      RUBY
      File.write(path, source)
      output = StringIO.new
      errors = StringIO.new
      status = Flexr::CLI.run(["check", path, "--format", "json"], out: output, err: errors)

      expect(status).to eq(1)
      start = source.b.index(statement)
      diagnostic = JSON.parse(errors.string).fetch(0)
      expect(diagnostic).to include("code" => "FLEXR-E029", "location" => [start, start + statement.bytesize])
      expect(diagnostic.fetch("message")).to include("LEFT & RIGHT")
      expect(diagnostic.fetch("note")).to include('left operand accepts "a"', 'right operand accepts "b"')
    end
  end
end
