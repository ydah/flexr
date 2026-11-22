# frozen_string_literal: true

require "json"
require "stringio"

RSpec.describe "emit shorthand advice" do
  it "suggests the shorthand for single emits of unmodified text" do
    source = <<~RUBY
      class EmitAdviceLexer < Flexr::Lexer
        rule("a") { emit :A }
        rule("b") { emit(:B, text) }
        rule("c") { emit(:C, text.upcase) }
        rule("d", skip: true) { emit :D }
        rule("e") { puts(text); emit :E }
        rule("f", emits: %i[F G]) { emit :F }
      end
    RUBY
    Dir.mktmpdir do |directory|
      path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(path, source)
      output = StringIO.new
      errors = StringIO.new
      status = Flexr::CLI.run(["check", path, "--format", "json", "--warn", "all", "--warn-as-error"], out: output, err: errors)
      expect(status).to eq(0), errors.string
      hints = JSON.parse(output.string).select { |item| item.fetch("code") == "FLEXR-I004" }
      expect(hints.map { |item| item.fetch("help") }).to eq(["use emit: :A on the rule", "use emit: :B on the rule"])
      expect(hints.map { |item| item.fetch("location").first }).to eq([source.b.index('rule("a")'), source.b.index('rule("b")')])
    end
  end
end
