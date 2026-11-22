# frozen_string_literal: true

require "stringio"

RSpec.describe "oedipus_lex import" do
  def import_source(source, output: nil)
    Dir.mktmpdir("flexr-oedipus") do |directory|
      path = File.join(directory, "lexer.rex")
      File.write(path, source)
      args = ["import", path, "--from", "oedipus_lex"]
      args.push("-o", output) if output
      out = StringIO.new
      err = StringIO.new
      status = Flexr::CLI.run(args, out: out, err: err)
      [status, out.string, err.string]
    end
  end

  it "keeps source order, alternation priority, macros, flags, and token values" do
    input = File.read(File.expand_path("fixtures/oedipus_subset.rex", __dir__))

    status, source, errors = import_source(input)
    expect(status).to eq(0), errors
    expect(source).to include("backend :firstmatch")
    expected = [[:FIRST, "a"], ["b", "b"], [:KEYWORD, true], [:PATH, "x/y"], [:NUMBER, 123]]
    Dir.mktmpdir("flexr-oedipus-generated") do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.write(path, source)
      [source, Flexr::Generator.new(path).generate].each do |representation|
        scope = Module.new
        scope.module_eval(representation)
        expect(scope::OriginalLexer.new("ab KW x/y 123").tokens).to eq(expected)
      end
    end
  end

  it "rejects executable sections, guards, states, and unsafe actions with source locations" do
    input = <<~REX
      require "support"
      class OriginalLexer < Parser
      option
        lineno
      start
        advance
      rule
        active? /x/ handle_x
        : /y/
        | /y/ { [:Y, text] }
        :STRING /z/ :STRING
        /a/ { [:A, Kernel.system("invalid")] }
        /b/ nil
      end
    REX

    Dir.mktmpdir("flexr-existing") do |path|
      output = File.join(path, "keep.rb")
      File.write(output, "untouched")
      status, source, errors = import_source(input, output: output)

      expect(status).to eq(1)
      expect(source).to be_empty
      expect(File.read(output)).to eq("untouched")
      expect(errors).to match(/lexer\.rex:1: .*header/)
      expect(errors).to match(/lexer\.rex:2: .*superclass/)
      expect(errors).to match(/lexer\.rex:4: .*lineno/)
      expect(errors).to match(/lexer\.rex:6: .*start/)
      expect(errors).to match(/lexer\.rex:8: .*predicate/)
      expect(errors).to match(/lexer\.rex:9: .*group/)
      expect(errors).to match(/lexer\.rex:11: .*state/)
      expect(errors).to match(/lexer\.rex:12: .*action/)
      expect(errors).to match(/lexer\.rex:13: .*state/)
    end
  end

  it "rejects interpolation and regexps outside the shared first-match subset" do
    input = <<~'REX'
      class OriginalLexer
      rule
        /#{MISSING}/ { [:X, text] }
        /#{raise "do not run"}/ { [:X, text] }
        /^a/ { [:X, text] }
        /a*/ { [:X, text] }
        /a(?=b)/ { [:X, text] }
        /a/n { [:X, text] }
      end
    REX

    status, source, errors = import_source(input)

    expect(status).to eq(1)
    expect(source).to be_empty
    expect(errors).to include("MISSING", "interpolation", "anchor", "empty", "lookahead", "flag")
  end
end
