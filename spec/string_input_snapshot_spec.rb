# frozen_string_literal: true

require "open3"
require "rbconfig"
require "stringio"

RSpec.describe "lexer string input snapshots" do
  let(:lexer_class) do
    Class.new(Flexr::Lexer) do
      rule(/[a-z]+/, emit: :WORD)
      rule(/ +/, skip: true)
    end
  end

  it "takes an immutable copy of a mutable string when the lexer is created" do
    source = +"before"
    lexer = lexer_class.new(source)

    expect(lexer.input).not_to equal(source)
    expect(lexer.input).to be_frozen
    source.replace("after")
    expect(lexer.tokens).to eq([[:WORD, "before"]])
  end

  it "reuses an already frozen string" do
    source = "before"

    expect(lexer_class.new(source).input).to equal(source)
  end

  it "retains the caller's string when freezing is disabled" do
    source = +"before"
    lexer = lexer_class.new(source, freeze_input: false)

    expect(lexer.input).to equal(source)
    source.replace("after")
    expect(lexer.tokens).to eq([[:WORD, "after"]])
  end

  it "continues to read streaming input in chunks" do
    source = StringIO.new("first last")
    lexer = lexer_class.new(source, chunk_size: 1, retain_input: false)

    expect(source.pos).to eq(0)
    expect(lexer.next_token).to eq([:WORD, "first"])
    expect(source.pos).to be < source.size
    expect(lexer.tokens).to eq([[:WORD, "last"]])
  end

  it "keeps snapshots frozen as consumed bytes are discarded" do
    [1, 64].each do |chunk_size|
      lexer = lexer_class.new(+"first secondword", retain_input: false, chunk_size: chunk_size)

      expect(lexer.next_token).to eq([:WORD, "first"])
      remaining = lexer.input
      expect(remaining).to eq(" secondword")
      expect { remaining.replace(" changed") }.to raise_error(FrozenError)
      expect(lexer.tokens).to eq([[:WORD, "secondword"]])
      expect(lexer.input).to be_empty.and be_frozen
    end
  end

  it "copies a pushed string when it is queued" do
    lexer = lexer_class.new("parent")
    source = +"before"
    lexer.push_input(source)
    source.replace("after")

    expect(lexer.tokens).to eq([[:WORD, "before"], [:WORD, "parent"]])
  end

  it "retains a queued string when freezing is disabled" do
    lexer = lexer_class.new("parent", freeze_input: false)
    source = +"before"
    lexer.push_input(source)
    source.replace("after")

    expect(lexer.tokens).to eq([[:WORD, "after"], [:WORD, "parent"]])
  end

  %i[generated standalone].each do |mode|
    it "takes the same snapshots and honors the same opt-out in #{mode} mode" do
      Dir.mktmpdir("flexr-input-snapshot") do |dir|
        spec = File.join(dir, "lexer.flexr.rb")
        File.binwrite(spec, <<~RUBY)
          require "flexr"

          class SnapshotFixture < Flexr::Lexer
            rule(/[a-z]+/, emit: :WORD)
            option :input_stack
          end
        RUBY
        output = File.join(dir, "lexer.rb")
        standalone = mode == :standalone
        Flexr::Generator.new(spec, output: output, options: { standalone: standalone }).generate

        runner = File.join(dir, "verify.rb")
        File.binwrite(runner, <<~'RUBY')
          require ARGV.fetch(0)

          [{}, { freeze_input: false }].each do |options|
            parent = +"parent"
            child = +"child"
            lexer = SnapshotFixture.new(parent, **options)
            lexer.push_input(child)
            parent.replace("changedparent")
            child.replace("changedchild")
            expected = options.empty? ? %w[child parent] : %w[changedchild changedparent]
            actual = lexer.tokens.map(&:last)
            abort "expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
          end
        RUBY
        command = [RbConfig.ruby, standalone ? "--disable-gems" : "-Ilib", runner, output]
        _, stderr, status = Open3.capture3({ "RUBYOPT" => nil, "RUBYLIB" => nil }, *command)
        expect(status).to be_success, stderr
      end
    end
  end
end
