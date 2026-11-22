# frozen_string_literal: true

require "json"
require "open3"
require "stringio"

RSpec.describe "lexer input stacks" do
  it "reads pending inputs in LIFO order with separate filenames and byte coordinates" do
    lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      accel :strscan
      rule(/[a-z]+/, emit: :WORD)
      rule(" ", skip: true)
    end.new("start end", filename: "outer.rb", max_steps: 100)

    expect(lexer.next_token.value).to eq("start")
    outer_steps = lexer.steps
    child = StringIO.new("first")
    lexer.push_input(child, filename: "first.rb")
    lexer.push_input("second", filename: "second.rb")
    expect(child.pos).to eq(0)

    tokens = lexer.tokens
    expect(tokens.map { |token| [token.value, token.location.filename, token.location.byte_begin] }).to eq(
      [["second", "second.rb", 0], ["first", "first.rb", 0], ["end", "outer.rb", 6]]
    )
    expect(lexer.steps).to be > outer_steps
    expect(child).not_to be_closed
    expect(lexer.filename).to eq("outer.rb")
  end

  it "uses the active string in the whole-token accelerator" do
    lexer = Class.new(Flexr::Lexer) do
      accel :strscan
      rule(/[a-z]+/, emit: :WORD)
      rule(" ", skip: true)
    end.new("start end")

    expect(lexer.next_token).to eq([:WORD, "start"])
    lexer.push_input("included")
    expect(lexer.tokens).to eq([[:WORD, "included"], [:WORD, "end"]])
  end

  it "leaves the current input and an earlier pending child intact when a push fails" do
    lexer = Class.new(Flexr::Lexer) { rule(/./, emit: :BYTE) }.new("ab", filename: "parent.lex", max_buffer_size: 2)

    expect(lexer.next_token).to eq([:BYTE, "a"])
    lexer.push_input("x", filename: "child.lex")
    expect { lexer.push_input(Object.new) }.to raise_error(ArgumentError, /String or IO/)
    expect { lexer.push_input("abc", filename: "oversize.lex") }.to raise_error(Flexr::Runtime::BufferTooLargeError) do |error|
      expect(error.filename).to eq("oversize.lex")
    end
    expect([lexer.filename, lexer.byte_pos]).to eq(["parent.lex", 1])
    expect(lexer.tokens).to eq([[:BYTE, "x"], [:BYTE, "b"]])
  end

  it "preserves parent less and more without combining text from the include" do
    lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule("ab") do
        less(1)
        more
        push_input("x", filename: "included")
      end
      rule("b", emit: :PARENT)
      rule("x", emit: :CHILD)
    end.new(StringIO.new("ab"), filename: "outer", chunk_size: 1, retain_input: false)

    tokens = lexer.tokens
    expect(tokens.map { |token| [token.type, token.value, token.location.filename, token.location.byte_end] }).to eq(
      [[:CHILD, "x", "included", 1], [:PARENT, "ab", "outer", 2]]
    )
  end

  it "allows an EOF action to emit and schedule another input exactly once per source" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/./, emit: :CHAR)
      on_eof do
        push_input("b", filename: "child") if filename == "root"
        emit :END, filename
      end
    end.new("a", filename: "root")

    expect(lexer.tokens).to eq([[:CHAR, "a"], [:END, "root"], [:CHAR, "b"], [:END, "child"]])
    expect(lexer.next_token).to be_nil
  end

  it "reports the active child's filename for lexical errors" do
    lexer = Class.new(Flexr::Lexer) { rule("a", emit: :A) }.new("a", filename: "root")
    lexer.push_input("?", filename: "sub/child.lex")

    expect { lexer.next_token }.to raise_error(Flexr::LexError) do |error|
      expect([error.filename, error.byte_pos, error.line]).to eq(["sub/child.lex", 0, 1])
    end
    expect(lexer.next_token).to eq([:A, "a"])
    expect(lexer.filename).to eq("root")
  end

  it "only permits a checkpoint to be used with its active input" do
    lexer = Class.new(Flexr::Lexer) { rule(/./, emit: :CHAR) }.new("a", filename: "root")
    root = lexer.checkpoint
    lexer.push_input("xy", filename: "child")

    expect(lexer.next_token).to eq([:CHAR, "x"])
    expect { lexer.restore(root) }.to raise_error(ArgumentError, /input/)
    child = lexer.checkpoint
    expect(lexer.next_token).to eq([:CHAR, "y"])
    expect(lexer.restore(child)).to equal(lexer)
    expect(lexer.next_token).to eq([:CHAR, "y"])
    expect(lexer.next_token).to eq([:CHAR, "a"])
    expect { lexer.restore(child) }.to raise_error(ArgumentError, /input/)
    expect(lexer.restore(root)).to equal(lexer)
    expect(lexer.next_token).to eq([:CHAR, "a"])
  end

  it "restores exclusive lexical state and input location in runtime, generated, and standalone lexers" do
    Dir.mktmpdir("flexr-input-stack") do |dir|
      source = File.join(dir, "lexer.flexr.rb")
      File.write(source, <<~'RUBY')
        require "flexr"
        require "stringio"
        class InputStackFixture < Flexr::Lexer
          token_kind :struct
          rule("[") { push(:outside) }
          rule("é", emit: :WORD)
          rule("\n", skip: true)
          rule("!") { push_input("β", filename: "nested.lex") }
          rule("β", emit: :NESTED)
          rule("x", emit: :TAIL)
          state(:outside) do
            rule("+") do
              push_input(StringIO.new("é\n!x"), filename: "child.lex")
              emit :INCLUDE, [text, filename, state]
            end
            rule("z") { pop; emit :OUTER, state }
          end
          on_eof { emit :END, filename }
        end
      RUBY
      variants = [[source, false]]
      %i[table direct firstmatch].product([false, true]).each do |backend, standalone|
        path = File.join(dir, "lexer.#{backend}.#{standalone}.rb")
        Flexr::Generator.new(source, output: path, options: { backend: backend, standalone: standalone }).generate
        variants << [path, standalone]
      end
      script = <<~RUBY
        require "json"
        load ARGV.fetch(0)
        lexer = InputStackFixture.new(StringIO.new("[+z"), filename: "root.lex", chunk_size: 1, retain_input: false)
        tokens = lexer.tokens.map do |token|
          loc = token.location
          value = token.value
          value = value.dup.force_encoding(Encoding::UTF_8) if value.is_a?(String)
          [token.type, value, loc.filename, loc.byte_begin, loc.byte_end, loc.line_begin, loc.column_begin]
        end
        puts JSON.generate(tokens)
      RUBY
      expected = [
        ["INCLUDE", ["+", "root.lex", "outside"], "root.lex", 1, 2, 1, 2],
        ["WORD", "é", "child.lex", 0, 2, 1, 1],
        ["NESTED", "β", "nested.lex", 0, 2, 1, 1],
        ["END", "nested.lex", "nested.lex", 2, 2, 1, 2],
        ["TAIL", "x", "child.lex", 4, 5, 2, 2],
        ["END", "child.lex", "child.lex", 5, 5, 2, 3],
        ["OUTER", "initial", "root.lex", 2, 3, 1, 3],
        ["END", "root.lex", "root.lex", 3, 3, 1, 4]
      ]

      variants.each do |path, standalone|
        command = [RbConfig.ruby]
        command.push("-Ilib") unless standalone
        stdout, stderr, status = Open3.capture3(*command, "-e", script, path)
        expect(status).to be_success, stderr
        expect(JSON.parse(stdout)).to eq(expected)
      end
    end
  end

  it "drains nested source layout and restores its checkpoints across all scanner modes" do
    Dir.mktmpdir("flexr-input-layout-") do |dir|
      source = File.join(dir, "lexer.flexr.rb")
      generated = File.join(dir, "lexer.generated.rb")
      standalone = File.join(dir, "lexer.standalone.rb")
      File.write(source, <<~'RUBY')
        require "flexr"
        require "stringio"
        class NestedLayoutFixture < Flexr::Lexer
          token_kind :struct
          indentation newline: :NL, indent: :IN, dedent: :OUT
          rule(/ +/, channel: :space)
          rule(/#[^\n]*/, channel: :comment)
          rule(/\n/, emit: :NL)
          rule("@") do
            if filename == "root.lex"
              push_input(StringIO.new("  child\n    @\n    peer"), filename: "child.lex")
            else
              push_input(StringIO.new("leaf\n    deep # tail"), filename: "leaf.lex")
            end
            emit :INCLUDE, filename
          end
          rule(/[a-z]+/, emit: :WORD)
          on_eof { emit :END, filename unless filename == "leaf.lex" }
        end
      RUBY
      Flexr::Generator.new(source, output: generated, options: { backend: :direct }).generate
      Flexr::Generator.new(source, output: standalone, options: { standalone: true }).generate
      script = <<~'RUBY'
        require "json"
        load ARGV.fetch(0)
        source = "root\n  before\n  @\n  after\nend"
        lexer = NestedLayoutFixture.new(StringIO.new(source), filename: "root.lex", chunk_size: 1)
        tokens = []
        loop do
          token = lexer.next_token
          abort "parent include token was not emitted" unless token

          tokens << token
          break if token.type == :INCLUDE
        end
        parent = lexer.checkpoint
        tokens << lexer.next_token
        child = lexer.checkpoint
        first = lexer.next_token
        tokens << lexer.restore(child).next_token
        abort "child checkpoint did not restore its queued word" unless first == tokens.last
        tokens.concat(lexer.tokens)
        resumed = lexer.restore(parent).tokens
        all = NestedLayoutFixture.new(StringIO.new(source), filename: "root.lex", chunk_size: 1, retain_input: false)
          .tokens(channels: :all)
        encode = ->(token) {
          [token.type, token.value, token.location.filename, token.location.byte_begin,
           token.leading_trivia.map(&:value)]
        }
        visible = all.select { |token| token.channel == :default }
        abort "all channels changed the layout stream" unless visible.map(&encode) == tokens.map(&encode)
        puts JSON.generate([tokens.map(&encode), resumed.map(&encode), all.select { |token| token.channel == :comment }.map(&encode)])
      RUBY
      parent_head = [
        ["WORD", "root", "root.lex", 0, []], ["NL", "\n", "root.lex", 4, []], ["IN", nil, "root.lex", 7, []],
        ["WORD", "before", "root.lex", 7, ["  "]], ["NL", "\n", "root.lex", 13, []],
        ["INCLUDE", "root.lex", "root.lex", 16, ["  "]]
      ]
      child = [
        ["IN", nil, "child.lex", 2, []], ["WORD", "child", "child.lex", 2, ["  "]],
        ["NL", "\n", "child.lex", 7, []], ["IN", nil, "child.lex", 12, []],
        ["INCLUDE", "child.lex", "child.lex", 12, ["    "]]
      ]
      leaf = [
        ["WORD", "leaf", "leaf.lex", 0, []], ["NL", "\n", "leaf.lex", 4, []], ["IN", nil, "leaf.lex", 9, []],
        ["WORD", "deep", "leaf.lex", 9, ["    "]], ["OUT", nil, "leaf.lex", 20, []]
      ]
      child_tail = [
        ["NL", "\n", "child.lex", 13, []], ["WORD", "peer", "child.lex", 18, ["    "]],
        ["OUT", nil, "child.lex", 22, []], ["OUT", nil, "child.lex", 22, []], ["END", "child.lex", "child.lex", 22, []]
      ]
      parent_tail = [
        ["NL", "\n", "root.lex", 17, []], ["WORD", "after", "root.lex", 20, ["  "]], ["NL", "\n", "root.lex", 25, []],
        ["OUT", nil, "root.lex", 26, []], ["WORD", "end", "root.lex", 26, []], ["END", "root.lex", "root.lex", 29, []]
      ]
      expected = [parent_head + child + leaf + child_tail + parent_tail, parent_tail, [["comment", "# tail", "leaf.lex", 14, []]]]
      [source, generated, standalone].each do |path|
        command = [RbConfig.ruby]
        command << "-Ilib" unless path == standalone
        stdout, stderr, status = Open3.capture3(*command, "-e", script, path)
        expect(status).to be_success, stderr
        expect(JSON.parse(stdout)).to eq(expected)
      end
    end
  end

  it "keeps bracket suppression local to the suspended input" do
    lexer = Class.new(Flexr::Lexer) do
      indentation newline: :NL, indent: :IN, dedent: :OUT, brackets: ["()"]
      rule(/ +/, skip: true)
      rule(/\n/, emit: :NL)
      rule(/[()]/, emit: :BRACKET)
      rule("!") do
        push_input("x\n  y", filename: "child.lex")
        emit :INCLUDE
      end
      rule(/[a-z]+/, emit: :WORD)
    end.new("a(\n  !\n b)\nc")

    expect(lexer.tokens.map(&:first)).to eq(%i[WORD BRACKET INCLUDE WORD NL IN WORD OUT WORD BRACKET NL WORD])
  end

  it "embeds the optional runtime when a caller outside a standalone grammar pushes input" do
    Dir.mktmpdir("flexr-input-stack-option") do |dir|
      source = File.join(dir, "lexer.flexr.rb")
      standalone = File.join(dir, "lexer.rb")
      File.write(source, <<~RUBY)
        require "flexr"
        class InputStackOptionFixture < Flexr::Lexer
          option :input_stack
          rule(/./, emit: :CHAR)
        end
      RUBY
      Flexr::Generator.new(source, output: standalone, options: { standalone: true }).generate
      script = <<~RUBY
        load ARGV.fetch(0)
        lexer = InputStackOptionFixture.new("a")
        lexer.push_input("b", filename: "extra.lex")
        abort "wrong token order" unless lexer.tokens == [[:CHAR, "b"], [:CHAR, "a"]]
      RUBY
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, standalone)
      expect(status).to be_success, stderr
    end
  end
end
