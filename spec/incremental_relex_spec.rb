# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "incremental lexing" do
  def edit(start_byte, end_byte, replacement)
    Flexr::Runtime::Edit.new(start_byte: start_byte, end_byte: end_byte, replacement: replacement)
  end

  def located(tokens)
    tokens.map { |token| [token.type, token.value, token.location.to_h, token.channel, located(token.leading_trivia)] }
  end

  it "reuses the unaffected prefix and converged suffix of a same-length edit" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/[a-z]+/, emit: :WORD)
      rule(" ", skip: true)
    end

    original = lexer.incremental("alpha beta gamma delta")
    revised = original.relex(edit(6, 10, "zedx"))

    expect(revised.input).to eq("alpha zedx gamma delta")
    expect(revised.tokens).to eq(lexer.new(revised.input).tokens)
    expect(revised.tokens.first).to equal(original.tokens.first)
    expect(revised.tokens[2]).to equal(original.tokens[2])
    expect(revised.tokens.last).to equal(original.tokens.last)
    expect(original.tokens[1]).to eq([:WORD, "beta"])
  end

  it "restarts before tokens whose longest match depended on the previous EOF" do
    lexer = Class.new(Flexr::Lexer) do
      rule("a", emit: :ATOM)
      rule(/a+z/, emit: :LONG)
    end

    original = lexer.incremental("aaaa")
    revised = original.relex(edit(4, 4, "z"))

    expect(original.tokens).to eq(Array.new(4) { [:ATOM, "a"] })
    expect(revised.tokens).to eq([[:LONG, "aaaaz"]])
  end

  it "relocates structured tokens and trivia across consecutive edits" do
    lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/[a-zé]+/, emit: :WORD)
      rule(/[ \n]+/, channel: :whitespace)
      rule(/#[^\n]*/, channel: :comment)
    end

    original = lexer.incremental("head # note\né xx zz\nlast", filename: "edit.txt")
    revised = original.relex(edit(0, 4, "a\nlonger"))
    expected = lexer.new(revised.input, filename: "edit.txt").tokens

    expect(located(revised.tokens)).to eq(located(expected))
    suffix = revised.tokens.find { |token| token.value == "é" }
    expect(suffix.location).to have_attributes(line_begin: 3, column_begin: 1)
    expect(suffix.leading_trivia.first.location).to have_attributes(line_begin: 2, column_begin: 7)

    second_start = revised.input.b.index("xx")
    completed = revised.relex(edit(second_start, second_start + 2, "m\néé"))
    expect(located(completed.tokens)).to eq(located(lexer.new(completed.input, filename: "edit.txt").tokens))
    expect(original.input).to eq("head # note\né xx zz\nlast")
  end

  it "preserves synthetic layout tokens when an edit shifts their positions" do
    lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      indentation newline: :NL, indent: :IN, dedent: :OUT
      rule("\n", emit: :NL)
      rule(/ +/, skip: true)
      rule(/[a-z]+/, emit: :WORD)
    end

    original = lexer.incremental("root\n  child\n    deep\n  peer\nend")
    revised = original.relex(edit(7, 12, "kid\n  next"))

    expect(revised.tokens.map(&:type)).to eq(%i[WORD NL IN WORD NL WORD NL IN WORD NL OUT WORD NL OUT WORD])
    expect(located(revised.tokens)).to eq(located(lexer.new(revised.input).tokens))
  end

  it "restarts before an earlier failed lookahead when a later insertion makes it succeed" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a(?=b+z)/, emit: :WITH_TAIL)
      rule("a", emit: :A)
      rule(/b+/, emit: :BS)
      rule("z", emit: :Z)
    end

    original = lexer.incremental("abbb")
    revised = original.relex(edit(4, 4, "z"))

    expect(original.tokens).to eq([[:A, "a"], [:BS, "bbb"]])
    expect(revised.tokens).to eq([[:WITH_TAIL, "a"], [:BS, "bbb"], [:Z, "z"]])
  end

  it "compares trailing lookbehind context before reusing an unchanged suffix" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/[ab]/, emit: :HEAD)
      rule("x", emit: :X)
      rule(" ", skip: true)
      rule("q", followed_by: /(?<=ax q)y/, emit: :WITH_CONTEXT)
      rule("q", emit: :Q)
      rule("y", emit: :Y)
    end

    original = lexer.incremental("ax qy")
    revised = original.relex(edit(0, 1, "b"))

    expect(original.tokens.map(&:first)).to eq(%i[HEAD X WITH_CONTEXT Y])
    expect(revised.tokens).to eq([[:HEAD, "b"], [:X, "x"], [:Q, "q"], [:Y, "y"]])
  end

  it "waits for the whole lexical state stack to converge when actions are pure" do
    lexer = Class.new(Flexr::Lexer) do
      rule("<") do
        push(:left)
        emit(:OPEN)
      end
      rule(">") do
        push(:right)
        emit(:OPEN)
      end
      rule("z", emit: :Z)

      state :left, :right do
        rule("[") do
          push(:inner)
          emit(:ENTER)
        end
        rule("!") do
          pop
          emit(:EXIT)
        end
      end
      state(:left) { rule("x", emit: :LEFT) }
      state(:right) { rule("x", emit: :RIGHT) }
      state :inner do
        rule("]") do
          pop
          emit(:LEAVE)
        end
      end
    end

    original = lexer.incremental("<[]x!zz", pure_actions: true)
    revised = original.relex(edit(0, 1, ">"))

    expect(original.tokens.map(&:first)).to eq(%i[OPEN ENTER LEAVE LEFT EXIT Z Z])
    expect(revised.tokens.map(&:first)).to eq(%i[OPEN ENTER LEAVE RIGHT EXIT Z Z])
    expect(revised.tokens.last).to equal(original.tokens.last)
  end

  it "runs arbitrary rule actions for the entire revised document" do
    calls = []
    lexer = Class.new(Flexr::Lexer) do
      rule(" ", skip: true)
      rule(/[a-z]/) do
        calls << text
        emit(:LETTER, calls.length)
      end
    end

    original = lexer.incremental("a b c")
    revised = original.relex(edit(2, 3, "x"))

    expect(calls).to eq(%w[a b c a x c])
    expect(original.tokens).to eq([[:LETTER, 1], [:LETTER, 2], [:LETTER, 3]])
    expect(revised.tokens).to eq([[:LETTER, 4], [:LETTER, 5], [:LETTER, 6]])
  end

  it "relexes incomplete editor input under the requested recovery policy" do
    lexer = Class.new(Flexr::Lexer) do
      rule(" ", skip: true)
      rule(/[a-z]/, emit: :LETTER)
    end

    original = lexer.incremental("a ? c", error_mode: :token)
    revised = original.relex(edit(2, 3, "b"))

    expect(original.tokens).to eq([[:LETTER, "a"], [:error, "?"], [:LETTER, "c"]])
    expect(revised.tokens).to eq([[:LETTER, "a"], [:LETTER, "b"], [:LETTER, "c"]])
  end

  it "validates half-open byte ranges and keeps prior input snapshots intact" do
    lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/./, emit: :CHARACTER)
    end
    input = +"éx"
    filename = +"editor.txt"
    original = lexer.incremental(input, filename: filename)
    input.replace("abc")
    filename.replace("other.txt")

    aggregate_failures do
      [[-1, 0], [2, 1], [0, 4], [0, 1], [1, 2]].each do |start_byte, end_byte|
        expect { original.relex(edit(start_byte, end_byte, "a")) }.to raise_error(ArgumentError)
      end
    end

    replacement = +"b"
    revised = original.relex(edit(0, 2, replacement))
    replacement.replace("c")

    expect(original.input).to eq("éx")
    expect(original.tokens.map(&:value)).to eq(%w[é x])
    expect(revised.input).to eq("bx")
    expect(revised.tokens.map(&:value)).to eq(%w[b x])
    expect(revised.tokens.map { |token| token.location.filename }).to eq(%w[editor.txt editor.txt])
  end

  [[:table, false], [:direct, true]].each do |backend, standalone|
    it "matches whole-input scanning and reuses its suffix in generated #{backend} mode with standalone=#{standalone}" do
      source = <<~RUBY
        class IncrementalParityLexer < Flexr::Lexer
          rule(" ", skip: true)
          rule(/[a-z]+/, emit: :WORD)
        end
      RUBY
      runner = <<~RUBY
        load ARGV.fetch(0)
        before = IncrementalParityLexer.incremental("begin middle ending")
        edit = Flexr::Runtime::Edit.new(start_byte: 6, end_byte: 12, replacement: "center")
        after = before.relex(edit)
        abort "tokens differ from a full scan" unless after.tokens == IncrementalParityLexer.new(after.input).tokens
        abort "suffix was rescanned" unless after.tokens.last.equal?(before.tokens.last)
      RUBY

      Dir.mktmpdir("flexr-incremental-") do |directory|
        specification = File.join(directory, "incremental.flexr.rb")
        artifact = File.join(directory, "incremental.rb")
        File.binwrite(specification, source)
        Flexr::Generator.new(specification, output: artifact, options: {backend: backend, standalone: standalone}).generate
        command = [RbConfig.ruby, *(standalone ? ["--disable-gems"] : %w[-Ilib -rflexr])]
        environment = standalone ? {"RUBYOPT" => nil, "RUBYLIB" => nil} : {}
        _output, error, status = Open3.capture3(environment, *command, "-e", runner, artifact)

        expect(status).to be_success, error
      end
    end
  end
end
