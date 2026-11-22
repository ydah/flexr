# frozen_string_literal: true

require "json"
require "open3"
require "stringio"

RSpec.describe "lexer delegation" do
  it "rebases the original repeated capture's UTF-8 byte, line, and column ranges" do
    child = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule("é", emit: :LETTER)
      rule("\r\n", skip: true)
      rule("same", emit: :WORD)
    end
    parent = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule("intro\n", emit: :HEAD)
      rule(/é=(?<js>é\r\nsame);/) { delegate child, capture: :js }
      rule("\r\n", skip: true)
      rule("end", emit: :TAIL)
    end
    input = StringIO.new("intro\né=é\r\nsame;\r\nend")
    scanner = parent.new(input, filename: "outer.html", chunk_size: 1, retain_input: false)

    tokens = scanner.tokens
    expect(tokens.map(&:type)).to eq(%i[HEAD LETTER WORD TAIL])
    expect(tokens[1].location).to have_attributes(
      filename: "outer.html", byte_begin: 9, byte_end: 11, line_begin: 2, line_end: 2, column_begin: 3, column_end: 4
    )
    expect(tokens[2].location).to have_attributes(byte_begin: 13, byte_end: 17, line_begin: 3, column_begin: 1)
    expect(tokens[3].location).to have_attributes(byte_begin: 20, line_begin: 4, column_begin: 1)
  end

  it "expands nested delegation in order and leaves the parent lexical state alone" do
    inner = Class.new(Flexr::Lexer) { rule(/[a-z]/, emit: :LETTER) }
    child = Class.new(Flexr::Lexer) do
      rule(/\{(?<code>[a-z]+)\}/) { delegate inner, capture: :code }
    end
    parent = Class.new(Flexr::Lexer) do
      rule("<") do
        push(:inside)
        emit :OPEN
      end
      state(:inside) do
        rule(/\[(?<code>\{[a-z]+\})\]/) do
          delegate child, capture: :code
          emit :SCOPE, state
        end
        rule("!") do
          emit :CLOSE, state
          pop
        end
      end
      rule(".", emit: :END)
    end
    scanner = parent.new("<[{ab}]!.")

    expect(Array.new(7) { scanner.racc_next_token }).to eq(
      [[:OPEN, "<"], [:LETTER, "a"], [:LETTER, "b"], %i[SCOPE inside], %i[CLOSE inside], [:END, "."], [false, "$end"]]
    )
    expect(scanner.state).to eq(:initial)
  end

  it "replays queued delegated tokens after restore and clears them on seek" do
    child = Class.new(Flexr::Lexer) { rule(/[a-z]/, emit: :LETTER) }
    parent = Class.new(Flexr::Lexer) do
      rule(/\[(?<code>[a-z]+)\]/) { delegate child, capture: :code }
      rule("!", emit: :TAIL)
    end
    scanner = parent.new("[ab]!")

    expect(scanner.next_token).to eq([:LETTER, "a"])
    mark = scanner.checkpoint
    expect(scanner.next_token).to eq([:LETTER, "b"])
    scanner.restore(mark)
    expect(scanner.next_token).to eq([:LETTER, "b"])
    scanner.restore(mark).seek(4)
    expect(scanner.tokens).to eq([[:TAIL, "!"]])
  end

  it "drains delegated tokens in their input frame before returning to the parent" do
    child = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/[a-z]/, emit: :LETTER)
    end
    host = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule("+") { push_input("[ab]", filename: "nested.html") }
      rule(/\[(?<code>[a-z]+)\]/) { delegate child, capture: :code }
      rule("!", emit: :TAIL)
    end
    scanner = host.new("+!", filename: "outer.html")

    expect(scanner.next_token.location).to have_attributes(filename: "nested.html", byte_begin: 1)
    nested = scanner.checkpoint
    expect(scanner.next_token.location).to have_attributes(filename: "nested.html", byte_begin: 2)
    scanner.restore(nested)
    expect(scanner.next_token.value).to eq("b")
    expect(scanner.next_token.location).to have_attributes(filename: "outer.html", byte_begin: 1)
    expect { scanner.restore(nested) }.to raise_error(ArgumentError, /different input/)
  end

  it "accounts for the host indentation once and leaves the child newline in order" do
    child = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule("!\n", emit: :NL)
      rule("text", emit: :CODE)
    end
    host = Class.new(Flexr::Lexer) do
      token_kind :struct
      indentation newline: :NL, indent: :IN, dedent: :OUT
      rule(/ +/, skip: true)
      rule(/\n/, emit: :NL)
      rule(/[a-z]+/, emit: :WORD)
      rule(/<(?<code>!\ntext)>/) { delegate child, capture: :code }
    end
    scanner = host.new(StringIO.new("root\n  <!\ntext>\nnext"), chunk_size: 1, retain_input: false)

    expect([scanner.next_token.type, scanner.next_token.type]).to eq(%i[WORD NL])
    indent = scanner.next_token
    expect(indent.type).to eq(:IN)
    expect(indent.location).to have_attributes(byte_begin: 7, byte_end: 7, line_begin: 2, column_begin: 3)
    expect(scanner.tokens.map(&:type)).to eq(%i[NL CODE NL OUT WORD])
  end

  it "prevents a delegated lexer from switching to an input outside its capture" do
    child = Class.new(Flexr::Lexer) do
      rule("a") { push_input("b", filename: "other.js") }
      rule("b", emit: :OTHER)
    end
    host = Class.new(Flexr::Lexer) do
      rule(/<(?<code>a)>/) { delegate child, capture: :code }
    end

    expect { host.new("<a>").next_token }.to raise_error(ArgumentError, /captured input/)
  end

  it "lets optional captures stay absent and processes explicit child EOF for an empty capture" do
    child = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule("a", emit: :A)
      on_eof { emit :CHILD_EOF }
    end
    parent = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/\[(?<code>a)?\]/) { delegate child, capture: :code }
      rule(/\{(?<code>a*)\}/) { delegate child, capture: :code }
    end

    tokens = parent.new("[]{}", filename: "empty.html").tokens
    expect(tokens.map(&:type)).to eq([:CHILD_EOF])
    expect(tokens[0].location).to have_attributes(filename: "empty.html", byte_begin: 3, byte_end: 3, column_begin: 4)
  end

  it "translates child errors and leaves the failed replacement without queued tokens" do
    child = Class.new(Flexr::Lexer) { rule("a", emit: :A) }
    parent = Class.new(Flexr::Lexer) do
      rule(/<(?<code>a\?)>/) { delegate child, capture: :code }
      rule("!", emit: :TAIL)
    end
    scanner = parent.new("<a?>!", filename: "error.html")

    expect { scanner.next_token }.to raise_error(Flexr::LexError) do |error|
      expect([error.filename, error.byte_pos, error.line]).to eq(["error.html", 2, 1])
    end
    expect(scanner.next_token).to eq([:TAIL, "!"])
    expect(parent.new("<a?>!", error_mode: :token).tokens).to eq([[:A, "a"], [:error, "?"], [:TAIL, "!"]])
  end

  it "rejects delegation outside a capture or outside the action's shortened range" do
    child = Class.new(Flexr::Lexer) { rule("a", emit: :A) }
    parent = Class.new(Flexr::Lexer) do
      rule(/<(?<code>a)>/) do
        delegate child, capture: :code
        less(1)
      end
    end
    instance = parent.new("<a>")

    expect { instance.delegate(child, capture: :code) }.to raise_error(ArgumentError, /capture action/)
    expect { instance.next_token }.to raise_error(ArgumentError, /current match/)
  end

  it "validates the capture name and the child's encoding and token representation" do
    child = Class.new(Flexr::Lexer) { rule("a", emit: :A) }
    binary_child = Class.new(Flexr::Lexer) do
      encoding Encoding::BINARY
      rule("a", emit: :A)
    end
    unknown = Class.new(Flexr::Lexer) do
      rule(/(?<code>a)/) { delegate child, capture: :typo }
    end
    encoding = Class.new(Flexr::Lexer) do
      rule(/(?<code>a)/) { delegate binary_child, capture: :code }
    end
    positioned = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/(?<code>a)/) { delegate child, capture: :code }
    end

    expect { unknown.new("a").next_token }.to raise_error(ArgumentError, /typo/)
    expect { encoding.new("a").next_token }.to raise_error(ArgumentError, /encoding/)
    expect { positioned.new("a").next_token }.to raise_error(ArgumentError, /struct/)
  end

  it "shares the parent's scan budget and bounds recursive source delegation" do
    child = Class.new(Flexr::Lexer) { rule("a", emit: :A) }
    parent = Class.new(Flexr::Lexer) do
      rule(/\[(?<code>a+)\]/) { delegate child, capture: :code }
    end
    recursive = Class.new(Flexr::Lexer) do
      rule(/(?<code>a)/) { delegate self.class, capture: :code }
    end

    expect { parent.new("[aaa]", max_steps: 8, filename: "steps.html").next_token }
      .to raise_error(Flexr::Runtime::StepLimitError)
    expect { recursive.new("a").next_token }.to raise_error(Flexr::LexError, /nesting/)
  end

  it "preserves and rebases child trivia when the parent also has a trivia channel" do
    child = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/ +/, channel: :spaces, emit: :SPACE)
      rule(/[a-z]/, emit: :ID)
    end
    parent = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule("!", channel: :prefix, emit: :PREFIX)
      rule(/<(?<code> a)>/) { delegate child, capture: :code }
    end

    token = parent.new("!< a>", filename: "trivia.html").next_token
    expect(token.type).to eq(:ID)
    expect(token.leading_trivia.map { |item| [item.channel, item.location.byte_begin] }).to eq([[:prefix, 0], [:spaces, 2]])
  end

  it "delegates absence-group bodies in runtime, generated, and standalone parent and child artifacts" do
    Dir.mktmpdir("flexr-delegate") do |directory|
      child = File.join(directory, "js.flexr.rb")
      parent = File.join(directory, "html.flexr.rb")
      File.write(child, <<~RUBY)
        require "flexr" unless defined?(Flexr::Lexer)
        class JsLexer < Flexr::Lexer
          token_kind :struct
          rule(/[a-z]+/, emit: :IDENT)
          rule(/[ ]+/, channel: :spaces, emit: :SPACE)
        end
      RUBY
      File.write(parent, <<~RUBY)
        require "flexr"
        require_relative "js"
        class HtmlLexer < Flexr::Lexer
          token_kind :struct
          rule(%r{<script>(?<js>(?~</script>))</script>}) { delegate JsLexer, capture: :js }
          rule(/[^<]+/, emit: :HTML)
        end
      RUBY

      variants = %i[runtime generated standalone].map do |mode|
        path = File.join(directory, mode.to_s)
        Dir.mkdir(path)
        js = File.join(path, "js.rb")
        html = File.join(path, "html.rb")
        if mode == :runtime
          File.write(js, File.read(child))
          File.write(html, File.read(parent))
        else
          Flexr::Generator.new(child, output: js).generate
          Flexr::Generator.new(parent, output: html, options: { standalone: mode == :standalone }).generate
        end
        [html, mode]
      end
      script = <<~RUBY
        require "json"
        require "stringio"
        load ARGV.fetch(0)
        input = StringIO.new("plain<script>first second</script>tail")
        tokens = HtmlLexer.new(input, filename: "site.html", chunk_size: 1, retain_input: false).tokens
        puts JSON.generate(tokens.map do |token|
          trivia = token.leading_trivia.map { |item| [item.channel, item.location.byte_begin] }
          [token.type, token.value, token.location.filename, token.location.byte_begin, trivia]
        end)
      RUBY
      expected = [["HTML", "plain", "site.html", 0, []], ["IDENT", "first", "site.html", 13, []],
                  ["IDENT", "second", "site.html", 19, [["spaces", 18]]], ["HTML", "tail", "site.html", 34, []]]
      variants.each do |path, mode|
        command = [RbConfig.ruby]
        command.push("-Ilib") unless mode == :standalone
        env = mode == :standalone ? { "RUBYOPT" => nil, "RUBYLIB" => nil } : {}
        stdout, stderr, status = Open3.capture3(env, *command, "-e", script, path)
        expect(status).to be_success, stderr
        expect(JSON.parse(stdout)).to eq(expected)
      end
    end
  end
end
