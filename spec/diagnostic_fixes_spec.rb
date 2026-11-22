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
end
