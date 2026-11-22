# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe "flexr new" do
  around do |example|
    Dir.mktmpdir("flexr-new") { |directory| Dir.chdir(directory) { example.run } }
  end

  def run_cli(*args)
    output = StringIO.new
    error = StringIO.new
    result = Flexr::CLI.run(["new", *args], out: output, err: error)
    [result, output.string, error.string]
  end

  it "explains the parser choices in its help" do
    status, output, error = run_cli("--help")

    expect(status).to eq(0), error
    expect(output).to include("Usage: flexr new NAME --parser lrama|racc")
    expect(Dir.children(".")).to be_empty
  end

  %w[racc lrama].each do |parser|
    it "creates a #{parser} calculator project" do
      status, output, error = run_cli("my-calc", "--parser", parser)

      expect(status).to eq(0), error
      expect(output).to include("my-calc", parser)
      expect(Dir.children("my-calc")).to contain_exactly(
        ".gitignore", "Gemfile", "README.md", "Rakefile", "calculator.rb",
        "lexer.flexr.rb", "parser.y", "test_calculator.rb"
      )
      expect(File.read("my-calc/Gemfile")).to include(%(gem "#{parser}"))
    end
  end

  it "validates the options and name before creating files" do
    [[], ["calc"], ["calc", "--parser"], ["calc", "--parser", "other"],
     ["calc", "--parser", "racc", "--standalone"], ["calc", "extra", "--parser", "racc"]].each do |arguments|
      status, _output, error = run_cli(*arguments)
      expect(status).to eq(2), error
      expect(Dir.children(".")).to be_empty
    end
  end

  it "accepts a directory name and rejects paths" do
    [".", "..", "../escape", "nested/calc", 'nested\calc', File.expand_path("absolute")].each do |name|
      status, _output, error = run_cli(name, "--parser", "racc")
      expect(status).to eq(2), error
      expect(error).to include("project name")
    end
    expect(Dir.children(".")).to be_empty
  end

  it "leaves existing directories, files, and symlinks intact" do
    Dir.mkdir("empty")
    Dir.mkdir("existing")
    File.write("existing/README.md", "keep me")
    File.write("occupied", "keep me")
    File.symlink("existing", "linked")
    File.symlink("missing", "dangling")

    %w[empty existing occupied linked dangling].each do |name|
      status, _output, error = run_cli(name, "--parser", "racc")
      expect(status).to eq(1), error
      expect(error).to include("already exists")
    end
    expect(Dir.children("empty")).to be_empty
    expect(Dir.children("existing")).to eq(["README.md"])
    expect(File.read("existing/README.md")).to eq("keep me")
    expect(File.read("occupied")).to eq("keep me")
    expect(File.readlink("linked")).to eq("existing")
    expect(File.readlink("dangling")).to eq("missing")
    expect(File.exist?("missing")).to be(false)
  end
end
