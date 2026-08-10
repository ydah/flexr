# frozen_string_literal: true

require "open3"
require "stringio"

require "spec_helper"

RSpec.describe "flexr dot" do
  let(:fixture) { File.expand_path("fixtures/generated.flexr.rb", __dir__) }

  def run_dot(spec = fixture)
    output = StringIO.new
    errors = StringIO.new
    status = Flexr::CLI.run(["dot", spec], out: output, err: errors)
    [status, output.string, errors.string]
  end

  it "distinguishes accepting and accelerated states with DOT attributes" do
    status, dot, errors = run_dot

    expect(status).to eq(0), errors
    expect(dot).to include('"initial_0" [shape=circle, label=""];')
    expect(dot).to include('"initial_1" [shape=doublecircle')
    expect(dot).to include('color="#D97706"', "style=filled", 'fillcolor="#FEF3C7"')
    expect(dot).to include('label="initial_1\\naccept=0"')
  end

  it "keeps state names in quoted node IDs and escapes them" do
    source = <<~RUBY
      require "flexr"

      class DotNamedStateLexer < Flexr::Lexer
        emits :A

        state :"quoted state" do
          rule(/a/) { emit :A }
        end
      end
    RUBY
    path = File.join(Dir.tmpdir, "flexr-dot-state-#{Process.pid}.flexr.rb")
    File.binwrite(path, source)

    _status, dot, errors = run_dot(path)

    expect(errors).to be_empty
    expect(dot).to include(Flexr::CLI.dot_quote("quoted state_0"))
    expect(dot).to include(Flexr::CLI.dot_quote("quoted state_1"))
    expect(Flexr::CLI.dot_quote('quoted "state"')).to eq('"quoted \\"state\\""')
  ensure
    FileUtils.rm_f(path) if path
  end

  it "produces Graphviz-compatible DOT" do
    _status, dot, errors = run_dot
    expect(errors).to be_empty

    begin
      svg, graphviz_errors, graphviz_status = Open3.capture3("dot", "-Tsvg", stdin_data: dot)
    rescue Errno::ENOENT
      skip "Graphviz dot executable is required for DOT compatibility verification"
    end

    expect(graphviz_status).to be_success, graphviz_errors
    expect(svg).to include("<svg")
  end
end
