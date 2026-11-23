# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "compiled DFA cache" do
  around do |example|
    old_directory = Flexr.cache_dir if Flexr.respond_to?(:cache_dir)
    Dir.mktmpdir("flexr-dfa-cache") do |directory|
      @directory = File.join(directory, "cache")
      example.run
    end
  ensure
    Flexr.cache_dir = old_directory if Flexr.respond_to?(:cache_dir=)
  end

  def lexer_for(pattern, value = :WORD)
    Class.new(Flexr::Lexer) do
      rule(pattern) { emit value }
    end
  end

  it "reuses the DFA in a fresh Ruby process with its own rule actions" do
    Flexr.cache_dir = @directory
    expect(lexer_for(/\p{L}+/).new("日本語").tokens).to eq([[:WORD, "日本語"]])
    expect(Dir.children(@directory).length).to eq(1)

    program = <<~'RUBY'
      require "flexr"
      Flexr.cache_dir = ARGV.fetch(0)
      Flexr::Automaton::NFABuilder.prepend(Module.new do
        def build(*) = abort("recompiled cached DFA")
      end)
      lexer = Class.new(Flexr::Lexer) { rule(/\p{L}+/) { emit :IDENTIFIER } }
      abort "wrong token" unless lexer.new("日本語").tokens == [[:IDENTIFIER, "日本語"]]
    RUBY
    _, stderr, status = Open3.capture3({ "RUBYOPT" => nil, "RUBYLIB" => nil }, RbConfig.ruby, "-Ilib", "-e", program, @directory)
    expect(status).to be_success, stderr
  end

  it "recompiles when a pattern or either version changes" do
    Flexr.cache_dir = @directory
    expect(lexer_for(/ab/).new("ab").tokens).to eq([[:WORD, "ab"]])
    expect(lexer_for(/ac/).new("ac").tokens).to eq([[:WORD, "ac"]])
    expect(Dir.children(@directory).length).to eq(2)

    stub_const("Flexr::VERSION", "changed-flexr-version")
    expect(lexer_for(/ab/).new("ab").tokens).to eq([[:WORD, "ab"]])
    expect(Dir.children(@directory).length).to eq(3)

    stub_const("Flexr::Unicode::VERSION", "changed-unicode-version")
    expect(lexer_for(/ab/).new("ab").tokens).to eq([[:WORD, "ab"]])
    expect(Dir.children(@directory).length).to eq(4)
  end

  it "keys a literal by the string that compilation sees" do
    Flexr.cache_dir = @directory
    literal = Class.new(String) do
      def to_s = "b"
    end.new("a")

    expect(lexer_for(literal).new("b").tokens).to eq([[:WORD, "b"]])
    expect(lexer_for("a").new("a").tokens).to eq([[:WORD, "a"]])
  end

  it "preserves priority, anchors, and freshly compiled actions on hits" do
    Flexr.cache_dir = @directory
    factory = lambda do |type, priority|
      Class.new(Flexr::Lexer) do
        rule(/a/, emit: :FALLBACK)
        rule(/^a/, priority: priority) { emit type }
        rule(/\n/, skip: true)
      end
    end
    expect(factory.call(:FIRST, 2).new("aa\na").tokens).to eq([[:FIRST, "a"], [:FALLBACK, "a"], [:FIRST, "a"]])
    expect(factory.call(:SECOND, 2).new("aa\na").tokens).to eq([[:SECOND, "a"], [:FALLBACK, "a"], [:SECOND, "a"]])
    expect(factory.call(:UNUSED, -1).new("aa\na").tokens).to eq([[:FALLBACK, "a"]] * 3)
    expect(Dir.children(@directory).length).to eq(2)
  end

  it "does not use a larger cached machine to bypass a DFA state limit" do
    Flexr.cache_dir = @directory
    lexer_for(/ab{4}c/).compile!
    limited = lexer_for(/ab{4}c/)
    limited.__flexr_config.options[:max_dfa_states] = 2

    expect { limited.compile! }.to raise_error(Flexr::CompileError, /DFA state limit exceeded/)
  end

  it "rebuilds a corrupt file and tolerates an unusable directory" do
    Flexr.cache_dir = @directory
    lexer_for(/a/).compile!
    cache_file = File.join(@directory, Dir.children(@directory).fetch(0))
    File.binwrite(cache_file, "truncated")

    expect(lexer_for(/a/).new("a").tokens).to eq([[:WORD, "a"]])
    expect(File.binread(cache_file)).not_to eq("truncated")

    Flexr.cache_dir = cache_file
    expect(lexer_for(/b/).new("b").tokens).to eq([[:WORD, "b"]])
  end

  it "stops reading and writing cached DFAs after disabling the cache" do
    Flexr.cache_dir = @directory
    lexer_for(/a/).compile!
    expect(Dir.children(@directory).length).to eq(1)
    Flexr.cache_dir = nil
    expect(Flexr.cache_dir).to be_nil

    expect(lexer_for(/b/).new("b").tokens).to eq([[:WORD, "b"]])
    expect(Dir.children(@directory).length).to eq(1)
  end

  it "generates the same source from cached DFA tables and current rule metadata" do
    source = File.join(File.dirname(@directory), "lexer.flexr.rb")
    File.write(source, <<~RUBY)
      class CacheFixture < Flexr::Lexer
        rule(/^(?<name>a)/, followed_by: /b/) { emit :FIRST, captures[:name] }
        rule(/[ab]/, emit: :LETTER)
        state :other do
          rule(/c/, emit: :OTHER)
        end
      end
    RUBY
    Flexr.cache_dir = @directory

    [false, true].each do |standalone|
      cold = Flexr::Generator.new(source, options: { standalone: standalone }).generate
      warm = Flexr::Generator.new(source, options: { standalone: standalone }).generate

      expect(warm).to eq(cold)
    end
  end
end
