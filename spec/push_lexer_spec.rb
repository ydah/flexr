# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "push lexing" do
  it "commits a terminal match immediately and keeps an extendable match pending" do
    lexer = Class.new(Flexr::Lexer) do
      rule("a", emit: :A)
      rule("ab", emit: :AB)
      rule("!", emit: :BANG)
    end

    stream = lexer.push
    expect(stream.feed("!a")).to eq([[:BANG, "!"]])
    expect(stream.feed("")).to eq([])
    expect(stream.feed("b!a")).to eq([[:AB, "ab"], [:BANG, "!"]])
    expect(stream.finish).to eq([[:A, "a"]])
    expect(stream.finish).to eq([])
    expect { stream.feed("!") }.to raise_error(IOError)
  end

  it "runs rule and EOF actions once across feed, empty input, and finish" do
    actions = []
    lexer = Class.new(Flexr::Lexer) do
      token_kind :yield
      rule(/[a-z]+/) do
        actions << text
        emit(:WORD, text)
      end
      rule(" ", skip: true)
      on_eof do
        actions << :finish
        emit(:END, :finish)
      end
    end

    stream = lexer.push
    emitted = []
    collect = ->(type, value) { emitted << [type, value] }

    expect(stream.feed("a", &collect)).to equal(stream)
    expect(stream.feed("b", &collect)).to equal(stream)
    expect(stream.feed("", &collect)).to equal(stream)
    expect(actions).to be_empty
    expect(stream.feed(" c", &collect)).to equal(stream)
    expect(actions).to eq(["ab"])
    expect(stream.finish(&collect)).to equal(stream)
    expect(emitted).to eq([[:WORD, "ab"], [:WORD, "c"], %i[END finish]])
    expect(stream.finish).to eq([])
    expect(actions).to eq(["ab", "c", :finish])
  end

  it "preserves UTF-8, lexical state, and source coordinates across byte boundaries" do
    lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule("\n", skip: true)
      rule("<") { begin_state(:body) }
      state :body do
        rule(/é+/, emit: :TEXT)
        rule(">") { begin_state(:initial) }
      end
      rule("!", emit: :BANG)
    end

    stream = lexer.push(filename: "stream")
    tokens = "\n<éé>!".b.bytes.flat_map { |byte| stream.feed(byte.chr) } + stream.finish

    expect(tokens.map(&:type)).to eq(%i[TEXT BANG])
    expect(tokens.map { |token| token.value.b }).to eq(["éé".b, "!".b])
    positions = tokens.map do |token|
      location = token.location
      [location.filename, location.byte_begin, location.byte_end, location.line_begin, location.column_begin]
    end
    expect(positions).to eq([["stream", 2, 6, 2, 2], ["stream", 7, 8, 2, 5]])
  end

  it "keeps EOF anchors and trailing context pending until they can be decided" do
    lexer = Class.new(Flexr::Lexer) do
      encoding Encoding::BINARY
      rule(/x\z/, emit: :FINAL)
      rule("x", emit: :X)
      rule("a", followed_by: "b", emit: :A)
      rule("a", emit: :PLAIN)
      rule("b", emit: :B)
    end

    stream = lexer.push
    expect(stream.feed("x")).to eq([])
    expect(stream.feed("a")).to eq([[:X, "x"]])
    expect(stream.feed("b")).to eq([[:A, "a"], [:B, "b"]])
    expect(stream.feed("x")).to eq([])
    expect(stream.finish).to eq([[:FINAL, "x"]])
  end

  it "rolls back past an accepted prefix without dropping the rest of the offered chunk" do
    lexer = Class.new(Flexr::Lexer) do
      rule("a", emit: :A)
      rule("abcx", emit: :LONG)
      rule(/[bcd!]/, emit: :BYTE)
    end

    stream = lexer.push
    expect(stream.feed("a")).to eq([])
    expect(stream.feed("bc")).to eq([])
    expect(stream.feed("d!")).to eq([[:A, "a"], [:BYTE, "b"], [:BYTE, "c"], [:BYTE, "d"], [:BYTE, "!"]])
    expect(stream.finish).to eq([])
  end

  it "resumes a delimiter action without invoking it again" do
    actions = []
    lexer = Class.new(Flexr::Lexer) do
      encoding Encoding::BINARY
      rule("[") do
        actions << :start
        emit(:BODY, scan_until("]"))
        actions << :done
      end
    end

    stream = lexer.push
    expect(stream.feed("[")).to eq([])
    expect(actions).to eq([:start])
    expect(stream.feed("text")).to eq([])
    expect(actions).to eq([:start])
    expect(stream.feed("]")).to eq([[:BODY, "text"]])
    expect(actions).to eq(%i[start done])
  end

  it "processes a chunk larger than the buffer while enforcing the live buffer limit" do
    lexer = Class.new(Flexr::Lexer) do
      rule("!", emit: :BANG)
      rule(/[a-z]+/, emit: :WORD)
    end

    stream = lexer.push(max_buffer_size: 2)
    expect(stream.feed("!!!!")).to eq(Array.new(4) { [:BANG, "!"] })
    expect(stream.feed("ab")).to eq([])
    expect { stream.feed("c") }.to raise_error(Flexr::Runtime::BufferTooLargeError)
  end

  it "restores a rule's checkpoint after the suspended lookahead resumes" do
    lexer = Class.new(Flexr::Lexer) do
      encoding Encoding::BINARY
      rule("a") do
        saved = checkpoint
        following = scan_until("!")
        restore(saved)
        emit :PEEK, following
      end
      rule("b", emit: :B)
      rule("!", emit: :BANG)
    end

    stream = lexer.push(retain_input: true)
    expect(stream.feed("ab")).to eq([])
    expect(stream.feed("!")).to eq([[:PEEK, "b"], [:B, "b"], [:BANG, "!"]])
    expect(stream.finish).to eq([])
  end

  it "commits a terminal match with work and cancellation guards enabled" do
    lexer = Class.new(Flexr::Lexer) { rule("!", emit: :BANG) }
    stream = lexer.push(max_steps: 20, cancellation: -> { false })

    expect(stream.feed("!")).to eq([[:BANG, "!"]])
  end

  it "commits a fixed firstmatch rule after rejecting an earlier prefix" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule("begin", emit: :BEGIN)
      rule("!", emit: :BANG)
    end

    expect(lexer.push.feed("!")).to eq([[:BANG, "!"]])
  end

  it "rejects reentrant feeding without replacing unread input" do
    lexer = Class.new(Flexr::Lexer) do
      rule("!", emit: :BANG)
      rule("?", emit: :QUESTION)
    end

    stream = lexer.push(chunk_size: 1)
    received = []
    stream.feed("!?") do |token|
      expect { stream.feed("!") }.to raise_error(IOError)
      received << token
    end

    expect(received).to eq([[:BANG, "!"], [:QUESTION, "?"]])
    expect(stream.finish).to eq([])
  end

  it "closes the stream when a callback breaks out of a feed" do
    lexer = Class.new(Flexr::Lexer) { rule("!", emit: :BANG) }
    stream = lexer.push(chunk_size: 1)

    expect(stream.feed("!!") { |token| break token }).to eq([:BANG, "!"])
    expect(stream.finish).to eq([])
    expect { stream.feed("!") }.to raise_error(IOError)
  end

  it "yields tokens to a scheduled producer fiber after that producer resumes" do
    scheduler = Class.new do
      attr_reader :waiting

      def fiber(&)
        Fiber.new(blocking: false, &).tap(&:resume)
      end

      def kernel_sleep(*)
        @waiting = Fiber.current
        Fiber.yield
      end

      def block(*) = raise("unexpected scheduler block")
      def unblock(*) = raise("unexpected scheduler unblock")
      def io_wait(*) = raise("unexpected I/O wait")
      def fiber_interrupt(*) = raise("unexpected fiber interrupt")
    end.new
    lexer = Class.new(Flexr::Lexer) { rule("ab", emit: :AB) }
    received = []

    Fiber.set_scheduler(scheduler)
    producer = Fiber.schedule do
      stream = lexer.push
      stream.feed("a") { |token| received << [Fiber.current, token] }
      sleep(0.001)
      stream.feed("b") { |token| received << [Fiber.current, token] }
      stream.finish
    end
    expect(scheduler.waiting).to equal(producer)
    expect(received).to eq([])

    producer.resume(0)
    expect(received).to eq([[producer, [:AB, "ab"]]])
    expect(producer).not_to be_alive
  ensure
    Fiber.set_scheduler(nil)
  end

  let(:lexer_source) do
    <<~'RUBY'
      class PushParityLexer < Flexr::Lexer
        token_kind :struct
        rule(/[a-z]+/, emit: :WORD)
        rule("::", emit: :SCOPE)
        rule(":", emit: :COLON)
        rule(/[ \r\n]+/, skip: true)
        rule("é", emit: :LETTER)
        on_eof { emit(:END, :eof) }
      end
    RUBY
  end

  let(:parity_runner) do
    <<~'RUBY'
      require "json"
      load ARGV.fetch(0)
      input = "foo::\r\né:bar"
      positions = ->(tokens) { tokens.map { |token| [token.type, token.value, token.location.byte_begin, token.location.byte_end] } }
      stream = PushParityLexer.push
      parts = input.b.bytes.flat_map { |byte| stream.feed(byte.chr) } + stream.finish
      puts JSON.generate([positions.call(PushParityLexer.new(input).tokens), positions.call(parts)])
    RUBY
  end

  [[:runtime, false], [:table, false], [:direct, true]].each do |backend, standalone|
    it "matches whole-input tokens in #{backend} mode with standalone=#{standalone}" do
      Dir.mktmpdir("flexr-push-") do |directory|
        source = File.join(directory, "push.flexr.rb")
        File.binwrite(source, lexer_source)
        artifact = source
        if backend != :runtime
          artifact = File.join(directory, "push.rb")
          Flexr::Generator.new(source, output: artifact, options: {backend: backend, standalone: standalone}).generate
        end
        command = [RbConfig.ruby, *(standalone ? ["--disable-gems"] : %w[-Ilib -rflexr])]
        environment = standalone ? {"RUBYOPT" => nil, "RUBYLIB" => nil} : {}
        output, error, status = Open3.capture3(environment, *command, "-e", parity_runner, artifact)

        expect(status).to be_success, error
        whole, push = JSON.parse(output)
        expect(whole.length).to eq(6)
        expect(push).to eq(whole)
      end
    end
  end
end
