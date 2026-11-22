# frozen_string_literal: true

require "stringio"

RSpec.describe "diagnostic fixes" do
  it "previews then atomically rewrites only actual capture groups" do
    source = <<~'RUBY'.gsub("\n", "\r\n")
      # é
      class FixCaptureLexer < Flexr::Lexer
        rule(/é(a)[()]/, emit: :A)
        rule(/\(b\)/, emit: :B)
      end
    RUBY
    fixed = source.sub("é(a)", "é(?:a)")
    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(path, source)
      output = StringIO.new
      errors = StringIO.new
      status = Flexr::CLI.run(["fix", path, "--dry-run"], out: output, err: errors)
      expect(status).to eq(0), errors.string
      expect(output.string.b).to eq(fixed.b)
      expect(File.binread(path)).to eq(source.b)

      status = Flexr::CLI.run(["fix", path], out: StringIO.new, err: errors)
      expect(status).to eq(0), errors.string
      expect(File.binread(path)).to eq(fixed.b)
    end
  end

  it "preserves native firstmatch patterns and never evaluates the spec" do
    source = <<~RUBY
      raise "must not run"
      class NativeCaptureLexer < Flexr::Lexer
        backend :firstmatch
        rule(/(a)/, emit: :A)
      end
    RUBY
    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(path, source)
      output = StringIO.new
      errors = StringIO.new
      status = Flexr::CLI.run(["fix", path, "--dry-run"], out: output, err: errors)
      expect(status).to eq(0), errors.string
      expect(output.string).to eq(source)
      expect(Flexr::CLI.run(["fix", path, "--eval"], out: output, err: errors)).to eq(2)
      expect(File.binread(path)).to eq(source)
    end
  end

  it "leaves rules with named captures untouched" do
    source = <<~RUBY
      class NamedCaptureFixLexer < Flexr::Lexer
        rule(/(a)(?<name>b)/) { emit :VALUE, captures[:name] }
      end
    RUBY
    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(path, source)
      errors = StringIO.new
      expect(Flexr::CLI.run(["fix", path], out: StringIO.new, err: errors)).to eq(0), errors.string
      expect(File.binread(path)).to eq(source)
    end
  end

  it "groups adjacent keywords and preserves both token types and values" do
    source = <<~RUBY
      class GroupedKeywordLexer < Flexr::Lexer
        rule("if", emit: :IF)
        rule("end", emit: :END)
        rule(/[a-z]+/, emit: :IDENT)
        rule(" ", skip: true)
      end
    RUBY
    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(path, source)
      errors = StringIO.new
      expect(Flexr::CLI.run(["fix", path], out: StringIO.new, err: errors)).to eq(0), errors.string
      fixed = File.binread(path)
      expect(fixed).to include('keywords ["if", "end"], among: :IDENT')
      expect(fixed).not_to include('rule("if"', 'rule("end"')
      [source, fixed].each do |definition|
        lexer = Module.new.tap { |scope| scope.module_eval(definition, path) }.const_get(:GroupedKeywordLexer)
        expect(lexer.new("if iffy end").tokens).to eq([[:IF, "if"], [:IDENT, "iffy"], [:END, "end"]])
      end
    end
  end

  it "exposes a shadowed literal without making the covering rule unreachable" do
    source = <<~RUBY
      class RepairPriorityLexer < Flexr::Lexer
        rule(/[a-z]+/, emit: :IDENT, priority: 7)
        rule("if", emit: :IF)
        rule(" ", skip: true)
      end
    RUBY
    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(path, source)
      errors = StringIO.new
      expect(Flexr::CLI.run(["fix", path], out: StringIO.new, err: errors)).to eq(0), errors.string
      fixed = File.binread(path)
      expect(fixed).to include('rule("if", emit: :IF, priority: 8)')
      lexer = Module.new.tap { |scope| scope.module_eval(fixed, path) }.const_get(:RepairPriorityLexer)
      expect(lexer.new("if iffy").tokens).to eq([[:IF, "if"], [:IDENT, "iffy"]])

      duplicate = source.sub("/[a-z]+/", '"if"')
      File.binwrite(path, duplicate)
      expect(Flexr::CLI.run(["fix", path], out: StringIO.new, err: errors)).to eq(0), errors.string
      expect(File.binread(path)).to eq(duplicate)
    end
  end

  it "rewrites lazy quoted patterns to stop at their first delimiters" do
    source = <<~RUBY
      class RepairAbsenceLexer < Flexr::Lexer
        rule(/".*?"/m, emit: :STRING)
        rule(/'.*?'/, emit: :SINGLE)
        rule(" ", skip: true)
      end
    RUBY
    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(path, source)
      errors = StringIO.new
      expect(Flexr::CLI.run(["fix", path], out: StringIO.new, err: errors)).to eq(0), errors.string
      fixed = File.binread(path)
      expect(fixed).to include('rule(/"(?~")"/m,')
      expect(fixed).to include("rule(/'(?~['\\n])'/,")
      lexer = Module.new.tap { |scope| scope.module_eval(fixed, path) }.const_get(:RepairAbsenceLexer)
      expect(lexer.new(%("a\n" "b")).tokens).to eq([[:STRING, %("a\n")], [:STRING, '"b"']])
      expect(lexer.new("'c'").tokens).to eq([[:SINGLE, "'c'"]])
    end
  end
end
