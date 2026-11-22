# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "reusable lexer rules" do
  let(:source) do
    <<~RUBY
      require "flexr"

      module RuleSetFixture
        module Common
          extend Flexr::Rules
          LETTER = /y/
          label = "shared "
          rule(/[ ]+/, channel: :space)
          rule("x", emit: :SHARED_X)
          rule(LETTER, priority: 1) { emit :SHARED_Y, label + text }
        end

        class Lexer < Flexr::Lexer
          token_kind :struct
          rule("x", emit: :FIRST_X)
          rule("y", emit: :FIRST_Y)
          rule("!") { begin_state :inside }
          use Common
          state :inside do
            use ::RuleSetFixture::Common
          end
        end
      end
    RUBY
  end

  it "expands rules in place in runtime, generated and standalone lexers" do
    Dir.mktmpdir("flexr-rule-sets") do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      generated = File.join(directory, "generated.rb")
      standalone = File.join(directory, "standalone.rb")
      File.write(path, source)
      Flexr::Generator.new(path, output: generated).generate
      Flexr::Generator.new(path, output: standalone, options: { standalone: true }).generate
      expect(Flexr::Generator.new(path).generate).to eq(File.read(generated))

      script = <<~RUBY
        require "json"
        load ARGV.fetch(0)
        lexer = RuleSetFixture::Lexer.new("x y!x y")
        puts JSON.generate(lexer.tokens(channels: :all).map { |token| [token.type, token.value, token.channel] })
      RUBY
      expected = [%w[FIRST_X x default], ["space", " ", "space"], ["SHARED_Y", "shared y", "default"],
                  %w[SHARED_X x default], ["space", " ", "space"], ["SHARED_Y", "shared y", "default"]]
      [path, generated, standalone].each do |file|
        load_path = file == standalone ? [] : ["-I", File.expand_path("../lib", __dir__)]
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, *load_path, "-e", script, file)
        expect(status).to be_success, stderr
        expect(JSON.parse(stdout)).to eq(expected)
      end
    end
  end

  it "takes a snapshot at use and requires subclasses to import rules explicitly" do
    rules = Module.new do
      extend Flexr::Rules
      rule("x", emit: :X)
    end
    parent = Class.new(Flexr::Lexer) { use rules }
    rules.rule("y", emit: :Y)
    child = Class.new(parent) { rule("y", emit: :CHILD_Y) }
    explicit = Class.new(parent) { use rules }

    expect(parent.new("x").tokens).to eq([[:X, "x"]])
    expect { parent.new("y").tokens }.to raise_error(Flexr::LexError)
    expect(child.new("y").tokens).to eq([[:CHILD_Y, "y"]])
    expect { child.new("x").tokens }.to raise_error(Flexr::LexError)
    expect(explicit.new("xy").tokens).to eq([[:X, "x"], [:Y, "y"]])
    expect { Class.new(Flexr::Lexer) { use Module.new } }.to raise_error(ArgumentError, /Flexr::Rules/)
  end

  it "rejects generated artifacts if executable Ruby changes the declarations at use" do
    changed = source.sub("  class Lexer <", "  Common.rule(\"z\", emit: :Z)\n  class Lexer <")
      .sub("::RuleSetFixture::Common", "Common")
    Dir.mktmpdir("flexr-rule-set-changed") do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.write(path, changed)
      generated = Flexr::Generator.new(path).generate

      expect { Module.new.module_eval(generated) }.to raise_error(Flexr::CompileError, /rule set.*changed/)
    end
  end

  it "uses Ruby's lexical lookup in a qualified lexer declaration" do
    code = <<~RUBY
      require "flexr"

      module Common
        extend Flexr::Rules
        rule("x", emit: :ROOT)
      end
      module NamespacedRules
        module Common
          extend Flexr::Rules
          rule("x", emit: :NESTED)
        end
      end
      class NamespacedRules::Lexer < Flexr::Lexer
        use Common
      end
    RUBY

    Dir.mktmpdir("flexr-rule-set-constant") do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.write(path, code)
      [code, Flexr::Generator.new(path).generate].each do |representation|
        scope = Module.new
        scope.module_eval(representation)
        expect(scope::NamespacedRules::Lexer.new("x").tokens).to eq([[:ROOT, "x"]])
      end
    end
  end

  it "reports missing rule sets at the constant reference" do
    code = "class MissingLexer < Flexr::Lexer\n  use MissingRules\nend\n"
    reader = Flexr::Source::PrismReader.new(code)
    expect { reader.read }.to raise_error(Flexr::StaticResolutionError) do |error|
      first = code.index("MissingRules")
      expect(error.diagnostic.location).to eq([first, first + "MissingRules".bytesize])
      expect(error.diagnostic.note).to include("rule set")
    end
  end

  it "reports unsupported nested declarations at the original rule" do
    code = source.sub('rule("x", emit: :SHARED_X)', 'if true; rule("x", emit: :SHARED_X); end')
    expect { Flexr::Source::PrismReader.new(code).read }.to raise_error(Flexr::StaticResolutionError) do |error|
      expect(error.diagnostic.location.first).to eq(code.index('rule("x", emit: :SHARED_X)'))
    end
  end
end
