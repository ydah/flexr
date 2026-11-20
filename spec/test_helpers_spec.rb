# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "lexer test helpers" do
  def lexer_class
    Class.new(Flexr::Lexer) do
      rule(/[0-9]+/) { emit :INTEGER, text.to_i }
      rule(/\+/) { emit :PLUS }
      rule(/\s+/, skip: true)
    end
  end

  before { require "flexr/rspec" }

  it "compares the complete token sequence and reports the differing value" do
    expect(lexer_class).to tokenize("12 + 3").as([[:INTEGER, 12], [:PLUS, "+"], [:INTEGER, 3]])
    expect(lexer_class).not_to tokenize("12").as([[:INTEGER, "12"]])
    expect do
      expect(lexer_class).to tokenize("12").as([[:INTEGER, 13]])
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /INTEGER.*13/m)
  end

  it "passes initialization options to generated lexers" do
    Dir.mktmpdir do |directory|
      source = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      File.write(source, <<~RUBY)
        class TestHelperGeneratedLexer < Flexr::Lexer
          rule(/[0-9]+/) { emit :INTEGER, text.to_i }
        end
      RUBY
      Flexr::Generator.new(source, output: output).generate
      load output
      expect(TestHelperGeneratedLexer).to tokenize("12", chunk_size: 1).as([[:INTEGER, 12]])
      expect do
        expect(TestHelperGeneratedLexer).to tokenize("12", max_token_size: 1).as([])
      end.to raise_error(Flexr::Runtime::TokenTooLargeError)
    ensure
      Object.send(:remove_const, :TestHelperGeneratedLexer) if Object.const_defined?(:TestHelperGeneratedLexer, false)
    end
  end

  it "requires explicit snapshot creation and preserves mismatched snapshots" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "tokens.json")
      expect do
        expect(lexer_class).to tokenize("12").matching_snapshot(path)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /missing.*update: true/m)
      expect(File.exist?(path)).to be(false)

      expect(lexer_class).to tokenize("12").matching_snapshot(path, update: true)
      original = File.binread(path)
      expect(lexer_class).to tokenize("12").matching_snapshot(path)
      expect do
        expect(lexer_class).to tokenize("13").matching_snapshot(path)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /snapshot.*tokens.json/m)
      expect(File.binread(path)).to eq(original)
      expect(lexer_class).to tokenize("13").matching_snapshot(path, update: true)
      expect(File.binread(path)).not_to eq(original)
    end
  end

  it "serializes symbols, binary text and hash key order deterministically" do
    require "flexr/testing"
    first = [[:VALUE, { :name => "a", "raw" => "\xff".b }]]
    second = [[:VALUE, { "raw" => "\xff".b, :name => "a" }]]
    rendered = Flexr::Testing::Snapshot.render(first)
    expect(Flexr::Testing::Snapshot.render(second)).to eq(rendered)
    expect(rendered).to include('"symbol"', '"bytes"', '255')
    expect(Flexr::Testing::Snapshot.render([[:VALUE, "name"]])).not_to eq(
      Flexr::Testing::Snapshot.render([%i[VALUE name]])
    )
    expect { Flexr::Testing::Snapshot.render([[:VALUE, Object.new]]) }
      .to raise_error(ArgumentError, /unsupported snapshot value/)
  end

  it "materializes structured token locations consistently" do
    require "flexr/testing"
    lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/é/) { emit :LETTER }
    end
    tokens = lexer.new("é", filename: "input.txt").tokens
    before = Flexr::Testing::Snapshot.render(tokens)
    tokens.first.location.column_begin
    tokens.first.location.column_end
    expect(Flexr::Testing::Snapshot.render(tokens)).to eq(before)
    expect(before).to include("column_begin", "column_end")
  end

  it "propagates missing-file errors from lexer actions" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a/) { File.read("/no-such-flexr-test-helper-input") }
    end
    expect do
      expect(lexer).to tokenize("a").matching_snapshot("/no-such-flexr-snapshot")
    end.to raise_error(Errno::ENOENT)
  end

  it "runs Minitest assertions and snapshots with actionable failures" do
    Dir.mktmpdir do |directory|
      source = File.join(directory, "lexer.flexr.rb")
      generated = File.join(directory, "lexer.rb")
      File.write(source, <<~RUBY)
        class MinitestGeneratedHelperLexer < Flexr::Lexer
          rule(/[0-9]+/) { emit :INTEGER, text.to_i }
        end
      RUBY
      Flexr::Generator.new(source, output: generated).generate
      script = <<~RUBY
        require "minitest/autorun"
        require "flexr/minitest"
        class HelperLexer < Flexr::Lexer
          rule(/[0-9]+/) { emit :INTEGER, text.to_i }
        end
        class MissingInputHelperLexer < Flexr::Lexer
          rule(/a/) { File.read("/no-such-flexr-test-helper-input") }
        end
        load ARGV.fetch(1)
        class HelperTest < Minitest::Test
          include Flexr::Minitest::Assertions
          def test_tokens
            assert_tokenize HelperLexer, "12", [[:INTEGER, 12]], chunk_size: 1
            assert_tokenize MinitestGeneratedHelperLexer, "12", [[:INTEGER, 12]], chunk_size: 1
            assert_raises(Minitest::Assertion) { assert_tokenize HelperLexer, "12", [[:INTEGER, 13]] }
            path = ARGV.fetch(0)
            assert_raises(Minitest::Assertion) { assert_token_snapshot HelperLexer, "12", path }
            refute_path_exists path
            assert_token_snapshot HelperLexer, "12", path, update: true
            assert_token_snapshot HelperLexer, "12", path
            assert_token_snapshot MinitestGeneratedHelperLexer, "12", path
            assert_raises(Minitest::Assertion) { assert_token_snapshot HelperLexer, "13", path }
            assert_raises(Errno::ENOENT) { assert_token_snapshot MissingInputHelperLexer, "a", path }
          end
        end
      RUBY
      runner = File.join(directory, "helper_test.rb")
      File.write(runner, script)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", runner, File.join(directory, "tokens.json"), generated)
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      expect(stdout).to include("0 failures", "0 errors")
    end
  end

  it "keeps test frameworks out of the normal runtime load" do
    script = 'require "flexr"; abort "test dependency loaded" if defined?(RSpec) || defined?(Minitest)'
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)
    expect(status).to be_success, "#{stdout}\n#{stderr}"
  end
end
