# frozen_string_literal: true

require "flexr/rspec"
require "open3"
require "rbconfig"

RSpec.describe "lexer language assertions" do
  it "proves whole-string inclusion and reports a string missing from the superset" do
    digits = Flexr::Lexer.pattern(/[0-9]+/)
    expect(digits).to include_language(Flexr::Lexer.pattern(/[0-9]{2}/))
    expect do
      expect(digits).to include_language(Flexr::Lexer.pattern(/0|x/))
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /"x"/)
  end

  it "checks the empty string, end conditions, and binary input for inclusion" do
    expect(/a$/).to include_language("a")
    expect(/a(?=b)/).not_to include_language("a")
    expect do
      expect(/a+/).to include_language(/a*/)
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /""/)
    expect(/\xff/n).to include_language("\xff".b, encoding: Encoding::BINARY)
  end

  it "finds the shared lexeme before rule priority resolves an overlap" do
    lexer = Class.new(Flexr::Lexer) do
      rule("if", emit: :IF)
      rule(/[a-z]+/, emit: :IDENT)
      rule(/[0-9]+/, emit: :NUMBER)
    end

    expect(lexer).to have_disjoint_tokens(:IF, :NUMBER)
    expect(lexer).not_to have_disjoint_tokens(:IF, :IDENT)
    expect do
      expect(lexer).to have_disjoint_tokens(:IF, :IDENT)
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /"if"/)
  end

  it "includes the surrounding source and byte offset in contextual overlap witnesses" do
    lexer = Class.new(Flexr::Lexer) do
      state(:inner, inclusive: false) do
        rule(/(?<=é)a(?=b)/, emit: :CONTEXTUAL)
        rule("a", emit: :PLAIN)
      end
    end
    expect do
      expect(lexer).to have_disjoint_tokens(:CONTEXTUAL, :PLAIN).in_state(:inner)
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /#{Regexp.escape('éab'.inspect)}.*byte 2/m)
  end

  it "compares trailing context against the same input suffix" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a/, followed_by: /b/, emit: :BEFORE_B)
      rule(/a/, followed_by: /c/, emit: :BEFORE_C)
      rule(/a/, followed_by: /[bc]/, emit: :BEFORE_EITHER)
    end

    expect(lexer).to have_disjoint_tokens(:BEFORE_B, :BEFORE_C)
    expect do
      expect(lexer).to have_disjoint_tokens(:BEFORE_B, :BEFORE_EITHER)
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /"ab"/)
  end

  it "uses the remapped kind for a keyword table candidate" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/[a-z]+/, emit: :IDENT)
      rule("if", emit: :OTHER)
      keywords({"if" => :IF}, among: :IDENT)
    end

    expect(lexer).to have_disjoint_tokens(:IF, :IDENT)
    expect(lexer).not_to have_disjoint_tokens(:IF, :OTHER)
  end

  it "proves equal rule selection in the requested state and reports a changed selection" do
    reference = Class.new(Flexr::Lexer) do
      rule("x", emit: :SAME)
      state(:inner, inclusive: false) { rule(/a(?=b)/, emit: :WORD) }
    end
    candidate = Class.new(Flexr::Lexer) do
      rule(/x/, emit: :SAME)
      state(:inner, inclusive: false) { rule(/ab/, emit: :WORD) }
    end

    expect(candidate).to tokenize_like(reference).in_state(:initial)
    expect(candidate).not_to tokenize_like(reference).in_state(:inner)
    expect do
      expect(candidate).to tokenize_like(reference).in_state(:inner)
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /inner.*"ab"/m)
  end

  it "compares analyzed firstmatch order for runtime and generated lexers" do
    runtime = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a+/, emit: :WORD)
      rule(/b|bc/, emit: :OTHER)
    end
    Dir.mktmpdir do |directory|
      source = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      File.write(source, <<~RUBY)
        class LanguageAssertionsGenerated < Flexr::Lexer
          backend :firstmatch
          rule(/[a]+/, emit: :WORD)
          rule(/b|bc/, emit: :OTHER)
        end
      RUBY
      Flexr::Generator.new(source, output: output).generate
      load output
      expect(LanguageAssertionsGenerated).to tokenize_like(runtime)
    ensure
      Object.send(:remove_const, :LanguageAssertionsGenerated) if Object.const_defined?(:LanguageAssertionsGenerated, false)
    end
  end

  it "fails both assertion polarities when a Ruby action is opaque" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a/) { raise "the matcher must not run actions" }
    end
    %i[to not_to].each do |polarity|
      expect do
        expect(lexer).public_send(polarity, tokenize_like(lexer))
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /opaque action/)
    end
  end

  it "exposes the same proofs and counterexamples through Minitest" do
    script = <<~RUBY
      require "minitest/autorun"
      require "flexr/minitest"

      class NumberLexer < Flexr::Lexer
        rule(/[0-9]+/, emit: :INTEGER)
        rule("if", emit: :KEYWORD)
      end

      class LanguageTest < Minitest::Test
        include Flexr::Minitest::Assertions

        def test_language
          assert_disjoint_tokens NumberLexer, :INTEGER, :KEYWORD
          assert_includes_language(/[0-9]+/, /[0-9]{2}/)
          assert_tokenize_like NumberLexer, NumberLexer, state: :initial
          failure = assert_raises(Minitest::Assertion) { assert_includes_language(/a/, /a|b/) }
          assert_includes failure.message, '"b"'
        end
      end
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)
    expect(status).to be_success, "#{stdout}\n#{stderr}"
    expect(stdout).to include("0 failures", "0 errors")
  end

  it "reports the compiler requirement in a standalone-only process" do
    Dir.mktmpdir do |directory|
      source = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      File.write(source, <<~RUBY)
        class StandaloneLanguageLexer < Flexr::Lexer
          rule(/a/, emit: :A)
          rule(/b/, emit: :B)
        end
      RUBY
      Flexr::Generator.new(source, output: output, options: {standalone: true}).generate
      script = <<~RUBY
        load ARGV.fetch(0)
        require "flexr/rspec"
        include RSpec::Matchers
        expect(StandaloneLanguageLexer).to tokenize("a").as([[:A, "a"]])
        expect do
          expect(StandaloneLanguageLexer).to have_disjoint_tokens(:A, :B)
        end.to raise_error(LoadError, /language assertions require the Flexr compiler/)
      RUBY
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script, output)
      expect(status).to be_success, "#{stdout}\n#{stderr}"
    end
  end
end
