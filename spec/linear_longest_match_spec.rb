# frozen_string_literal: true

require "open3"
require "rbconfig"
require "stringio"

RSpec.describe "longest-match backup" do
  def count_byte_reads(input, &)
    reads = 0
    trace = TracePoint.new(:c_call) do |event|
      reads += 1 if event.method_id == :getbyte && event.self.equal?(input)
    end
    trace.enable(&)
    reads
  end

  let(:lexer_class) do
    Class.new(Flexr::Lexer) do
      rule(/a/, emit: :A)
      rule(/a*b/, emit: :AB)
    end
  end

  it "bounds the number of byte reads as the input grows" do
    [256, 512].each do |length|
      input = ("a" * length).freeze

      reads = count_byte_reads(input) do
        expect(lexer_class.new(input).tokens).to eq([[:A, "a"]] * length)
      end
      expect(reads).to be <= length * 8
    end
  end

  it "bounds failed matches before any acceptance when an error handler skips bytes" do
    recovery_class = Class.new(Flexr::Lexer) { rule(/a*b/, emit: :AB) }
    input = ("a" * 256).freeze
    lexer = recovery_class.new(input)
    lexer.on_error = ->(_error) { :skip }

    reads = count_byte_reads(input) { expect(lexer.tokens).to be_empty }
    expect(reads).to be <= 256 * 8
  end

  it "bounds repeated failures through a cycle with more than one DFA state" do
    input = ("ab" * 256).freeze
    lexer = Class.new(Flexr::Lexer) do
      rule(/[ab]/, emit: :LETTER)
      rule(/(?:ab)*z/, emit: :END)
    end.new(input)

    reads = count_byte_reads(input) do
      expect(lexer.tokens).to eq([[:LETTER, "a"], [:LETTER, "b"]] * 256)
    end
    expect(reads).to be <= input.bytesize * 8
  end

  it "waits for a jam or confirmed EOF before treating a stream suffix as failed" do
    input = StringIO.new("aaaab#{'a' * 64}")
    lexer = lexer_class.new(input, retain_input: false, chunk_size: 2)

    expect(lexer.next_token).to eq([:AB, "aaaab"])
    expect(lexer.tokens).to eq([[:A, "a"]] * 64)
  end

  it "preserves long matches after a borrowed string is mutated" do
    input = +"aaaa"
    lexer = lexer_class.new(input, freeze_input: false)

    expect(lexer.next_token).to eq([:A, "a"])
    input[-1] = "b"

    expect(lexer.tokens).to eq([[:AB, "aab"]])
  end

  it "does not assume an overridden byte reader stays stable when a string is frozen" do
    alternate = false
    input = Class.new(String) do
      define_method(:getbyte) do |index|
        alternate && index == 3 ? "b".ord : super(index)
      end
    end.new("aaaa").freeze
    lexer = lexer_class.new(input)

    expect(lexer.next_token).to eq([:A, "a"])
    alternate = true
    expect(lexer.tokens).to eq([[:AB, "aaa"]])
  end

  it "stops using the failure table when the loaded stream bytes can be mutated" do
    lexer = lexer_class.new(StringIO.new("aaaa"), chunk_size: 2)

    expect(lexer.next_token).to eq([:A, "a"])
    lexer.input[-1] = "b"

    expect(lexer.tokens).to eq([[:AB, "aab"]])
  end

  it "preserves a valid body before a stray UTF-8 continuation in a stream" do
    input = "a\x80".b.force_encoding(Encoding::UTF_8)
    lexer = lexer_class.new(StringIO.new(input), error_mode: :token, chunk_size: 1)

    expect(lexer.tokens).to eq([[:A, "a"], [:error, "\x80".b]])
  end

  it "scopes failures to the input before resuming a suspended scanner" do
    lexer = lexer_class.new("aaaa")

    expect(lexer.next_token).to eq([:A, "a"])
    lexer.push_input("aaab")

    expect(lexer.tokens).to eq([[:AB, "aaab"]] + ([[:A, "a"]] * 3))
  end

  it "uses the same failed suffix with different token expectations" do
    lexer = lexer_class.new("aaaa")

    expect(lexer.next_token(expect: [:A])).to eq([:A, "a"])
    expect(lexer.next_token).to eq([:A, "a"])
    expect(lexer.next_token(expect: [:A])).to eq([:A, "a"])
    expect(lexer.next_token).to eq([:A, "a"])
  end

  it "keeps raw acceptances that a previous token expectation rejected" do
    lexer = lexer_class.new("aaaaab")

    expect(lexer.next_token(expect: [:A])).to eq([:A, "a"])
    expect(lexer.next_token(expect: [:AB])).to eq([:AB, "aaaab"])
  end

  it "checks the current token limit even when a later scan already proved failure" do
    lexer = lexer_class.new("aaaaa", max_token_size: 4)
    checkpoint = lexer.checkpoint
    lexer.seek(1)
    expect(lexer.next_token).to eq([:A, "a"])
    lexer.restore(checkpoint)

    expect { lexer.next_token }.to raise_error(Flexr::Runtime::TokenTooLargeError)
  end

  it "preserves rule actions that shorten accepted matches" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/aa/) do
        less(1)
        emit :SHORT
      end
      rule(/a/, emit: :A)
      rule(/a*b/, emit: :AB)
    end.new("aaaa")

    expect(lexer.tokens).to eq([[:SHORT, "a"], [:SHORT, "a"], [:SHORT, "a"], [:A, "a"]])
  end

  it "still ranks trailing context and exposes only the consumed body" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a/, emit: :A)
      rule(/a*b/, followed_by: /c/, emit: :AB)
      rule(/c/, emit: :C)
    end.new("aaabcaaaa")

    expect(lexer.tokens).to eq([[:AB, "aaab"], [:C, "c"], *([[:A, "a"]] * 4)])
  end

  it "preserves generated acceleration and cancellation steps with error recovery enabled" do
    Dir.mktmpdir("flexr-guarded-backup") do |dir|
      source = File.join(dir, "lexer.flexr.rb")
      File.write(source, <<~RUBY)
        class GuardedBackupFixture < Flexr::Lexer
          accel :strscan
          rule(/x*b/, emit: :LONG)
        end
      RUBY
      output = File.join(dir, "lexer.rb")
      Flexr::Generator.new(source, output: output).generate
      runner = <<~RUBY
        require "flexr"
        load ARGV.fetch(0)
        lexer = GuardedBackupFixture.new("xxxxxxxxb", error_mode: :token, cancellation: ->(scanner) { scanner.steps == 3 })
        abort "wrong token or step count" unless lexer.tokens == [[:LONG, "xxxxxxxxb"]] && lexer.steps == 11
        ordinary = GuardedBackupFixture.new("xxxxxxxxb")
        abort "wrong ordinary tokens" unless ordinary.tokens == [[:LONG, "xxxxxxxxb"]]
      RUBY
      _, stderr, status = Open3.capture3({ "RUBYOPT" => nil, "RUBYLIB" => nil }, RbConfig.ruby, "-Ilib", "-e", runner, output)
      expect(status).to be_success, stderr
    end
  end

  it "starts memoizing generated failures when an error handler is installed after scanning began" do
    Dir.mktmpdir("flexr-recovery-backup") do |dir|
      source = File.join(dir, "lexer.flexr.rb")
      File.write(source, <<~RUBY)
        class RecoveryBackupFixture < Flexr::Lexer
          rule(/x*b/, emit: :LONG)
        end
      RUBY
      namespace = Module.new
      namespace.module_eval(Flexr::Generator.new(source).generate, source)
      input = "b#{'x' * 512}".freeze
      lexer = namespace::RecoveryBackupFixture.new(input)
      expect(lexer.next_token).to eq([:LONG, "b"])
      lexer.on_error = ->(_error) { :skip }

      reads = count_byte_reads(input) { expect(lexer.tokens).to be_empty }
      expect(reads).to be <= 512 * 8
    end
  end

  [[:table, false], [:direct, false], [:table, true], [:direct, true]].each do |backend, standalone|
    it "uses the same linear scan with #{backend} generation and standalone=#{standalone}" do
      Dir.mktmpdir("flexr-linear-scan") do |dir|
        spec = File.join(dir, "lexer.flexr.rb")
        File.binwrite(spec, <<~RUBY)
          require "flexr"

          class BackupFixture < Flexr::Lexer
            backend #{backend.inspect}
            rule(/a/, emit: :A)
            rule(/a*b/, emit: :AB)

            state :only_long do
              rule(/a*b/, emit: :AB)
            end

            state :anchored do
              rule(/^a/, emit: :A)
              rule(/x*b/, emit: :LONG)
            end
          end
        RUBY
        output = File.join(dir, "lexer.rb")
        Flexr::Generator.new(spec, output: output, options: { standalone: standalone }).generate
        runner = <<~'RUBY'
          require ARGV.fetch(0)

          def count_reads(input, &)
            reads = 0
            trace = TracePoint.new(:c_call) do |event|
              reads += 1 if event.method_id == :getbyte && event.self.equal?(input)
            end
            trace.enable(&)
            reads
          end

          input = ("a" * 512).freeze
          reads = count_reads(input) do
            abort "incorrect tokens" unless BackupFixture.new(input).tokens == [[:A, "a"]] * 512
          end
          abort "read #{reads} bytes" unless reads <= 512 * 8

          recovering = BackupFixture.new(input, error_mode: :panic)
          recovering.begin_state(:only_long)
          reads = count_reads(input) { abort "unexpected recovery tokens" unless recovering.tokens.empty? }
          abort "read #{reads} bytes during recovery" unless reads <= 512 * 8

          bad = "a\x80".b.force_encoding(Encoding::UTF_8)
          anchored = BackupFixture.new(bad, error_mode: :token)
          anchored.begin_state(:anchored)
          abort "lost anchored token" unless anchored.tokens == [[:A, "a"], [:error, bad.byteslice(1, 1)]]
        RUBY
        command = [RbConfig.ruby, standalone ? "--disable-gems" : "-Ilib", "-e", runner, output]
        _, stderr, status = Open3.capture3({ "RUBYOPT" => nil, "RUBYLIB" => nil }, *command)
        expect(status).to be_success, stderr
      end
    end
  end
end
