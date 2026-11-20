# frozen_string_literal: true

require "stringio"

RSpec.describe "v2 migration preparation" do
  around do |example|
    previous = Warning[:deprecated]
    Warning[:deprecated] = true
    example.run
  ensure
    Warning[:deprecated] = previous
  end

  it "warns for public record mutation while preserving v1 behavior" do
    token = Flexr::Runtime::Token.new(type: :A, value: "a")
    expect { token.value = "b" }.to output(/deprecated.*Token.*immutable.*2\.0/i).to_stderr
    expect(token.value).to eq("b")
    expect { token[:type] = :B }.to output(/deprecated.*Token.*immutable.*2\.0/i).to_stderr
    expect(token.type).to eq(:B)
  end

  it "warns for Location mutation but keeps column reads quiet" do
    location = Flexr::Runtime::Location.new(column_values: [1, 2])
    expect { location.column_begin }.not_to output.to_stderr
    expect { location.column_end = 9 }.to output(/deprecated.*Location.*immutable.*2\.0/i).to_stderr
    expect(location.column_end).to eq(9)
  end

  it "warns early for unknown error modes without changing v1 initialization" do
    lexer = Class.new(Flexr::Lexer) { rule(/a/, skip: true) }
    expect { lexer.new("a", error_mode: :typo) }.to output(/deprecated.*error_mode.*2\.0/i).to_stderr
  end

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
