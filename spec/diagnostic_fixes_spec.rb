# frozen_string_literal: true

require "stringio"

RSpec.describe "diagnostic fixes" do
  def terminal(text = "")
    StringIO.new(text.dup).tap { |stream| allow(stream).to receive(:tty?).and_return(true) }
  end

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

  it "leaves the declaration site of shared keyword rules unchanged" do
    source = <<~RUBY
      module SharedKeywordRules
        extend Flexr::Rules
        rule("if", emit: :IF)
        rule("end", emit: :END)
        rule(/[a-z]+/, emit: :IDENT)
      end
      class SharedKeywordLexer < Flexr::Lexer
        use SharedKeywordRules
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

  it "reports a changed token before allowing a non-interactive priority fix" do
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
      status = Flexr::CLI.run(["fix", path], out: StringIO.new, err: errors)
      expect(status).to eq(1), errors.string
      expect(File.binread(path)).to eq(source)
      expect(errors.string).to include('"if" at byte 0', ':IDENT("if")', ':IF("if")', "--accept-changes")

      output = StringIO.new
      errors = StringIO.new
      expect(Flexr::CLI.run(["fix", path, "--dry-run"], out: output, err: errors)).to eq(0), errors.string
      expect(output.string).to include("priority: 8")
      expect(errors.string).to include('"if" at byte 0')
      expect(File.binread(path)).to eq(source)

      expect(Flexr::CLI.run(["fix", path, "--accept-changes"], out: StringIO.new, err: StringIO.new)).to eq(0)
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

  it "requires approval when the original lazy quoted patterns cannot compile" do
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
      expect(Flexr::CLI.run(["fix", path], out: StringIO.new, err: errors)).to eq(2), errors.string
      expect(File.binread(path)).to eq(source)
      expect(errors.string).to include("FLEXR-E014", "--accept-changes")

      expect(Flexr::CLI.run(["fix", path, "--accept-changes"], out: StringIO.new, err: StringIO.new)).to eq(0)
      fixed = File.binread(path)
      expect(fixed).to include('rule(/"(?~")"/m,')
      expect(fixed).to include("rule(/'(?~['\\n])'/,")
      lexer = Module.new.tap { |scope| scope.module_eval(fixed, path) }.const_get(:RepairAbsenceLexer)
      expect(lexer.new(%("a\n" "b")).tokens).to eq([[:STRING, %("a\n")], [:STRING, '"b"']])
      expect(lexer.new("'c'").tokens).to eq([[:SINGLE, "'c'"]])
    end
  end

  it "asks for terminal confirmation after displaying the changed token" do
    source = <<~RUBY
      class ConfirmFixLexer < Flexr::Lexer
        rule(/[a-z]+/, emit: :IDENT)
        rule("if", emit: :IF)
      end
    RUBY
    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(path, source)
      errors = terminal
      input = terminal("\nyes\n")
      allow(input).to receive(:gets).and_wrap_original do |read|
        expect(errors.string).to include(':IDENT("if")', ':IF("if")', "[y/N]")
        read.call
      end
      expect(Flexr::CLI.run(["fix", path], input: input, out: StringIO.new, err: errors)).to eq(1)
      expect(File.binread(path)).to eq(source)
      expect(Flexr::CLI.run(["fix", path], input: input, out: StringIO.new, err: errors)).to eq(0)
      expect(File.binread(path)).to include("priority: 1")
    end
  end

  it "leaves opaque fixes for review and does not read a redirected confirmation" do
    source = <<~RUBY
      class OpaqueFixLexer < Flexr::Lexer
        rule(/(a)/, emit: :A)
        rule(/b/) { emit resolve_token }
      end
    RUBY
    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(path, source)
      errors = StringIO.new
      input = terminal("yes\n")
      expect(Flexr::CLI.run(["fix", path], input: input, out: StringIO.new, err: errors)).to eq(2)
      expect(errors.string).to include("opaque action")
      expect(input.pos).to eq(0)
      expect(File.binread(path)).to eq(source)
    end
  end

  it "preserves edits made while waiting for terminal confirmation" do
    source = <<~RUBY
      class ConcurrentFixLexer < Flexr::Lexer
        rule(/[a-z]+/, emit: :IDENT)
        rule("if", emit: :IF)
      end
    RUBY
    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(path, source)
      input = terminal
      updated = "#{source}# changed during confirmation\n"
      allow(input).to receive(:gets) do
        File.binwrite(path, updated)
        "yes\n"
      end
      errors = terminal
      expect(Flexr::CLI.run(["fix", path], input: input, out: StringIO.new, err: errors)).to eq(1)
      expect(errors.string).to include("spec changed")
      expect(File.binread(path)).to eq(updated)
    end
  end
end
