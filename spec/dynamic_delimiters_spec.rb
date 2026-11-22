# frozen_string_literal: true

require "json"
require "open3"
require "stringio"

RSpec.describe "dynamic delimiters" do
  it "consumes the first literal delimiter across chunks and expands the match" do
    lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule("[") do
        text
        emit :BODY, scan_until("aba")
      end
      rule(/./m, emit: :OTHER)
    end.new(StringIO.new("[éaabaaba"), filename: "literal.lex", chunk_size: 1, retain_input: false)

    token = lexer.next_token
    expect([token.type, token.value.b]).to eq([:BODY, "éa".b])
    expect(token.location.to_h.slice(:filename, :byte_begin, :byte_end, :line_end, :column_end)).to eq(
      filename: "literal.lex", byte_begin: 0, byte_end: 7, line_end: 1, column_end: 7
    )
    expect(lexer.tokens.map(&:value)).to eq(%w[a b a])
  end

  it "finds an overlapping literal delimiter" do
    lexer = Class.new(Flexr::Lexer) do
      rule("[") { emit :BODY, scan_until("ababac") }
    end.new(StringIO.new("[abababac"), chunk_size: 1)

    expect(lexer.tokens).to eq([[:BODY, "ab"]])
  end

  it "accepts an exact beginning-of-line delimiter with CRLF or no final newline" do
    lexer = Class.new(Flexr::Lexer) do
      rule("!") { emit :BODY, scan_until_line("TAG") }
      rule(/[a-z]+/, emit: :TAIL)
    end

    source = "!TAG\r\nnearTAG\nTAGX\r\nTAG\r\nnext"
    expect(lexer.new(StringIO.new(source), chunk_size: 1).tokens).to eq([[:BODY, "TAG\r\nnearTAG\nTAGX\r\n"], [:TAIL, "next"]])
    expect(lexer.new("!\nTAG").tokens).to eq([[:BODY, "\n"]])
  end

  it "returns an empty body when the delimiter is already at the cursor" do
    lexer = Class.new(Flexr::Lexer) do
      rule("[\n") { emit :BODY, scan_until_line("TAG") }
    end.new("[\nTAG\n")

    expect(lexer.tokens).to eq([[:BODY, ""]])
    expect(lexer.byte_pos).to eq(6)
  end

  it "returns nil at EOF without changing the cursor or match when the delimiter is missing" do
    lexer = Class.new(Flexr::Lexer) do
      rule("[") { emit :MISSING, [scan_until("end"), text, byte_pos] }
      rule(/[a-z]+/, emit: :WORD)
      on_eof { emit :EOF }
    end.new(StringIO.new("[en"), chunk_size: 1, retain_input: false)

    expect(lexer.tokens).to eq([[:MISSING, [nil, "[", 1]], [:WORD, "en"], [:EOF, ""]])
  end

  it "uses the cursor adjusted by less and carries the extended match into more" do
    lexer = Class.new(Flexr::Lexer) do
      rule("(!") do
        less(1)
        scan_until("]")
        more
      end
      rule("z", emit: :JOINED)
    end.new(StringIO.new("(!abc]z"), chunk_size: 1, retain_input: false)

    expect(lexer.tokens).to eq([[:JOINED, "(!abc]z"]])
  end

  it "clears the memoized text and lets less shorten the extended match" do
    lexer = Class.new(Flexr::Lexer) do
      rule("!") do
        text
        value = scan_until("💡")
        expanded = text
        less(1 + value.bytesize)
        emit :BODY, [value, expanded, text]
      end
      rule("💡", emit: :DELIMITER)
    end.new("!é💡")

    expect(lexer.tokens).to eq([[:BODY, ["é", "!é💡", "!é"]], [:DELIMITER, "💡"]])
  end

  it "validates delimiter shape and permits byte delimiters in binary mode" do
    unicode = Class.new(Flexr::Lexer) do
      rule("!") { scan_until("\xA9".b) }
    end.new("!é")
    line = Class.new(Flexr::Lexer) do
      rule("!") { scan_until_line("bad\nline") }
    end.new("!x")
    binary = Class.new(Flexr::Lexer) do
      encoding Encoding::BINARY
      rule("!") { emit :BODY, scan_until("\xA9".b) }
    end.new("!é".b)

    expect { unicode.next_token }.to raise_error(ArgumentError, /UTF-8/)
    expect { line.next_token }.to raise_error(ArgumentError, /newline/)
    expect(binary.tokens).to eq([[:BODY, "\xC3".b]])
  end

  it "confines delimiter helpers to a matched rule action" do
    lexer = Class.new(Flexr::Lexer) do
      rule("a", emit: :A)
      on_eof { scan_until("!") }
    end.new("a")

    expect { lexer.scan_until("!") }.to raise_error(ArgumentError, /rule action/)
    expect(lexer.next_token).to eq([:A, "a"])
    expect { lexer.scan_until_line("!") }.to raise_error(ArgumentError, /rule action/)
    expect { lexer.next_token }.to raise_error(ArgumentError, /rule action/)
  end

  it "honors the token and work limits with context from the active rule" do
    lexer = Class.new(Flexr::Lexer) do
      rule("!") { emit :BODY, scan_until("END") }
    end

    long = lexer.new("!abcdEND", filename: "big.lex", max_token_size: 4)
    expect { long.next_token }.to raise_error(Flexr::Runtime::TokenTooLargeError) do |error|
      expect([error.filename, error.byte_pos, error.rule]).to eq(["big.lex", 0, 0])
    end
    expect { long.scan_until("END") }.to raise_error(ArgumentError, /rule action/)
    guarded = lexer.new(StringIO.new("!abcdEND"), max_steps: 4, chunk_size: 1)
    expect { guarded.next_token }.to raise_error(Flexr::Runtime::StepLimitError)
  end

  it "has the same tagged body and UTF-8 byte positions in runtime, generated, and standalone lexers" do
    Dir.mktmpdir("flexr-dynamic-delimiter") do |directory|
      source = File.join(directory, "lexer.flexr.rb")
      File.write(source, <<~'RUBY')
        require "flexr"
        class DelimiterFixture < Flexr::Lexer
          token_kind :struct
          rule(/<<[A-Z]+\r?\n/) { emit :HEREDOC, scan_until_line(text.delete_prefix("<<").strip) }
          rule(/[a-z]+/, emit: :WORD)
        end
      RUBY
      variants = [[source, false]]
      %i[table direct firstmatch].product([false, true]).each do |backend, standalone|
        path = File.join(directory, "lexer.#{backend}.#{standalone}.rb")
        Flexr::Generator.new(source, output: path, options: { backend: backend, standalone: standalone }).generate
        variants << [path, standalone]
      end
      script = <<~'RUBY'
        require "json"
        require "stringio"
        load ARGV.fetch(0)
        source = StringIO.new("<<TAG\r\né\r\nTAG\r\nend")
        tokens = DelimiterFixture.new(source, filename: "heredoc.lex", retain_input: false, chunk_size: 1).tokens
        puts JSON.generate(tokens.map do |token|
          loc = token.location
          [token.type, token.value.dup.force_encoding(Encoding::UTF_8), loc.filename,
           loc.byte_begin, loc.byte_end, loc.line_begin, loc.line_end, loc.column_end]
        end)
      RUBY

      variants.each do |path, standalone|
        command = [RbConfig.ruby]
        command.push("-Ilib") unless standalone
        stdout, stderr, status = Open3.capture3(*command, "-e", script, path)
        expect(status).to be_success, stderr
        expect(JSON.parse(stdout)).to eq([
          ["HEREDOC", "é\r\n", "heredoc.lex", 0, 16, 1, 4, 1],
          ["WORD", "end", "heredoc.lex", 16, 19, 4, 4, 4]
        ])
      end
    end
  end

  it "can embed the standalone helper for indirect action calls" do
    Dir.mktmpdir("flexr-dynamic-delimiter-option") do |directory|
      source = File.join(directory, "lexer.flexr.rb")
      standalone = File.join(directory, "lexer.rb")
      File.write(source, <<~RUBY)
        require "flexr"
        class DelimiterOptionFixture < Flexr::Lexer
          option :dynamic_delimiters
          rule("!") { emit :BODY, send(:scan_until, "!") }
        end
      RUBY
      Flexr::Generator.new(source, output: standalone, options: { standalone: true }).generate
      script = <<~RUBY
        load ARGV.fetch(0)
        abort "wrong token" unless DelimiterOptionFixture.new("!a!").tokens == [[:BODY, "a"]]
      RUBY
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, standalone)
      expect(status).to be_success, stderr
    end
  end
end
