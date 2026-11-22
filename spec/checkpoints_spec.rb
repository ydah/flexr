# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

RSpec.describe "lexer checkpoints and seeking" do
  let(:words) do
    Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/[a-zé]+/, emit: :WORD)
      rule(/\n/, skip: true)
      rule(/^!/, emit: :BOL)
      rule(/!/, emit: :OTHER)
    end
  end

  it "restores a saved stack, accumulated text, and coordinates on the owning lexer" do
    klass = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule('"') do
        push(:quoted)
        more
        emit(:OPEN)
      end
      state :quoted do
        rule(/[^"]+/) do
          more
          skip
        end
        rule('"') do
          pop
          emit(:STRING)
        end
      end
    end
    lexer = klass.new(StringIO.new("\"é\nx\""), chunk_size: 1)
    expect(lexer.next_token.type).to eq(:OPEN)
    bookmark = lexer.checkpoint
    first = lexer.next_token
    expect(first.value.b).to eq("\"é\nx\"".b)
    expect(first.location).to have_attributes(byte_begin: 0, byte_end: 6, line_begin: 1, line_end: 2)
    expect(bookmark).to be_frozen

    expect(lexer.restore(bookmark)).to be(lexer)
    expect([lexer.state, lexer.byte_pos, lexer.lineno]).to eq([:quoted, 1, 1])
    expect(lexer.next_token).to eq(first)
    expect(lexer.state).to eq(:initial)
    expect { klass.new("\"é\nx\"").restore(bookmark) }.to raise_error(ArgumentError, /checkpoint/)
    expect { lexer.dup.restore(bookmark) }.to raise_error(ArgumentError, /checkpoint/)
  end

  it "restores a pending token and allows an EOF action to fire again without refunding work" do
    klass = Class.new(Flexr::Lexer) do
      rule("a", skip: true)
      on_eof { emit(:EOF, "") }
    end
    lexer = klass.new("a", max_steps: 100)
    pending = lexer.emit(:BEFORE, "pending")
    bookmark = lexer.checkpoint
    pending[0] = :CHANGED
    lexer.skip
    expect(lexer.next_token).to eq([:EOF, ""])
    expect(lexer.next_token).to be_nil
    work = lexer.steps

    lexer.restore(bookmark)
    expect(lexer.steps).to eq(work)
    expect(lexer.tokens).to eq([[:BEFORE, "pending"], [:EOF, ""]])
    expect(lexer.steps).to be > work
  end

  it "seeks by byte while preserving the lexical stack and recomputing locations without executing rules" do
    actions = []
    klass = Class.new(Flexr::Lexer) do
      token_kind :struct
      state :inside do
        rule(/[a-zé]+/) do
          actions << text
          emit(:WORD)
        end
        rule(/^!/, emit: :BOL)
      end
    end
    lexer = klass.new("é\n!a")
    lexer.push(:inside)

    expect(lexer.seek(3)).to be(lexer)
    expect(actions).to be_empty
    expect([lexer.state, lexer.byte_pos, lexer.lineno, lexer.beginning_of_line?]).to eq([:inside, 3, 2, true])
    expect(lexer.next_token).to have_attributes(type: :BOL, value: "!")
    expect(lexer.next_token.location).to have_attributes(byte_begin: 4, line_begin: 2, column_begin: 2)
    lexer.seek(0)
    expect(lexer.next_token.location).to have_attributes(byte_begin: 0, column_begin: 1, column_end: 2)
    expect(lexer.pop).to eq(:initial)
  end

  it "leaves the cursor and previous match unchanged after an invalid seek" do
    lexer = words.new("é\n!a")
    first = lexer.next_token

    expect { lexer.seek(1) }.to raise_error(ArgumentError, /UTF-8/)
    expect { lexer.seek(8) }.to raise_error(RangeError)
    expect { lexer.seek(-1) }.to raise_error(RangeError)
    expect { lexer.seek(1.0) }.to raise_error(ArgumentError, /Integer/)
    expect([lexer.byte_pos, lexer.lineno, lexer.text, lexer.last_location]).to eq([2, 1, "é", first.location])
    expect(lexer.next_token.type).to eq(:BOL)
  end

  it "seeks through buffered IO without reading ahead or pinning discarded input" do
    io = StringIO.new("aé\n!a")
    lexer = words.new(io, chunk_size: 2)
    lexer.buffer.ensure_available?(2)

    expect { lexer.seek(2) }.to raise_error(ArgumentError, /UTF-8/)
    expect { lexer.seek(4) }.to raise_error(RangeError)
    expect([io.pos, lexer.byte_pos]).to eq([2, 0])
    expect(lexer.next_token.value.b).to eq("aé".b)
    lexer.seek(1)
    expect(lexer.next_token.value.b).to eq("é".b)

    dropping = words.new(StringIO.new("a\n!a"), retain_input: false, chunk_size: 1)
    early = dropping.checkpoint
    dropping.next_token
    expect { dropping.restore(early) }.to raise_error(RangeError, /discarded/)
    expect { dropping.seek(0) }.to raise_error(RangeError, /discarded/)
    expect(dropping.byte_pos).to eq(1)
    expect(dropping.next_token.type).to eq(:BOL)
  end

  it "can seek back through retained more text until the buffer discards it" do
    klass = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule("a", emit: :A)
      rule("b") do
        more
        emit(:B)
      end
      rule("c", emit: :C)
    end
    lexer = klass.new(StringIO.new("abc"), retain_input: false, chunk_size: 1)
    lexer.next_token
    token = lexer.next_token
    bookmark = lexer.checkpoint

    expect(lexer.seek(1).next_token).to eq(token)
    lexer.restore(bookmark)
    expect(lexer.next_token.value).to eq("bc")
    expect { lexer.restore(bookmark) }.to raise_error(RangeError, /discarded/)
  end

  it "can seek to any byte in binary mode and resume after a halt" do
    klass = Class.new(Flexr::Lexer) do
      encoding Encoding::BINARY
      token_kind :struct
      rule(/[\x80-\xBF]/n, emit: :TAIL)
    end
    lexer = klass.new("é")
    lexer.on_error = ->(_) { :halt }
    expect(lexer.next_token).to be_nil
    halted = lexer.checkpoint

    token = lexer.seek(1).next_token
    expect(token.value.b).to eq("\xA9".b)
    expect(token.location).to have_attributes(byte_begin: 1, column_begin: 2)
    expect(lexer.restore(halted).next_token).to be_nil
  end

  it "adds positioning to an existing installed ABI 2 artifact" do
    fixture = File.expand_path("fixtures/generated.rb", __dir__)
    scope = Module.new
    scope.module_eval(File.read(fixture), fixture)
    lexer = scope.const_get(:GeneratedFixture).const_get(:Lexer).new("12 34")
    bookmark = lexer.checkpoint

    expect(lexer.seek(3).next_token).to eq([:INT, 34])
    expect(lexer.restore(bookmark).next_token).to eq([:INT, 12])
  end

  it "has the same positioning and EOF behavior in runtime, generated and standalone lexers" do
    source = <<~'RUBY'
      require "flexr"
      class ReplayingLexer < Flexr::Lexer
        token_kind :struct
        rule(/[a-zé]+/, emit: :WORD)
        rule(/\n/, skip: true)
        rule(/^!/, emit: :BOL)
        on_eof { emit(:EOF, "") }
      end
    RUBY
    consumer = <<~'RUBY'
      require "json"
      load ARGV.fetch(0)
      lexer = ReplayingLexer.new("é\n!b")
      checkpoint = lexer.checkpoint
      lexer.seek(3)
      rows = lexer.tokens.map { |token| [token.type, token.value, token.location.to_h] }
      lexer.restore(checkpoint)
      puts JSON.generate([rows, lexer.next_token.value, lexer.byte_pos, lexer.lineno])
    RUBY
    Dir.mktmpdir("flexr-checkpoints-") do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      generated = File.join(directory, "lexer.generated.rb")
      standalone = File.join(directory, "lexer.standalone.rb")
      File.binwrite(path, source)
      Flexr::Generator.new(path, output: generated).generate
      Flexr::Generator.new(path, output: standalone, options: { standalone: true }).generate

      outcomes = [path, generated, standalone].map do |file|
        command = [RbConfig.ruby]
        command.push("-I", File.expand_path("../lib", __dir__)) unless file == standalone
        output, errors, status = Open3.capture3(*command, "-e", consumer, file)
        expect(status).to be_success, errors
        JSON.parse(output)
      end
      expect(outcomes.uniq.length).to eq(1)
      expect(outcomes.first.drop(1)).to eq(["é", 2, 1])
      expect(outcomes.first.first.map(&:first)).to eq(%w[BOL WORD EOF])
    end
  end
end
