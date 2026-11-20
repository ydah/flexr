# frozen_string_literal: true

require "stringio"

RSpec.describe "v2 migration checks" do
  it "reports migration requirements and source locations without executing the spec" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "migration.flexr.rb")
      source = "raise 'must not execute'\nclass MigrationLexer < Flexr::Lexer\n  token_kind :struct\n  rule(/a/, skip: true)\nend\n"
      File.write(path, source)
      output = StringIO.new
      errors = StringIO.new
      status = Flexr::CLI.run(["check", path, "--target", "2.0", "--format", "json"], out: output, err: errors)
      expect(status).to eq(0), errors.string
      items = JSON.parse(output.string)
      expect(items.map { |item| item.fetch("code") }).to include("FLEXR-I002", "FLEXR-W020")
      expect(items.find { |item| item.fetch("code") == "FLEXR-I002" }.fetch("message"))
        .to include("Ruby 3.4", "regenerate")
      warning = items.find { |item| item.fetch("code") == "FLEXR-W020" }
      offset = source.index("token_kind")
      expect(warning.fetch("location")).to eq([offset, offset + "token_kind :struct".bytesize])
      expect(warning.fetch("help")).to include("with(", "consumer")
    end
  end

  it "limits target selection to static check and rejects unknown targets" do
    [["stats", "fixture.rb", "--target", "2.0"], ["check", "fixture.rb", "--target", "3.0"],
     ["check", "fixture.rb", "--target", "2.0", "--eval"]].each do |arguments|
      expect(Flexr::CLI.run(arguments, out: StringIO.new, err: StringIO.new)).to eq(2)
    end
  end
end
