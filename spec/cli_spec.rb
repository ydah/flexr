# frozen_string_literal: true

require "stringio"

RSpec.describe Flexr::CLI do
  let(:spec_path) { File.expand_path("fixtures/generated.flexr.rb", __dir__) }

  def run_cli(*arguments)
    output = StringIO.new
    errors = StringIO.new
    status = described_class.run(arguments, out: output, err: errors)
    [status, output.string, errors.string]
  end

  it "accepts the documented validation and generation flags" do
    status, output, errors = run_cli(
      "check", spec_path,
      "--backend", "direct", "--token-kind", "struct", "--accel", "none",
      "--standalone", "--table-compression", "rows", "--table-format", "packed",
      "--max-dfa-states", "100", "--warn", "none", "--color", "never", "--format", "json"
    )

    expect(status).to eq(0)
    expect(output).to eq("[]\n")
    expect(errors).to be_empty
  end

  it "returns usage failure for unknown flags" do
    status, _output, errors = run_cli("check", spec_path, "--not-a-real-flag")

    expect(status).to eq(2)
    expect(errors).to include("unknown option")
  end

  it "returns failure for import because conversion is not implemented" do
    status, output, _errors = run_cli("import", spec_path)

    expect(status).to eq(1)
    expect(output).to include("FLEXR-TODO")
  end

  it "supports version and rule-filtered explain output" do
    version_status, version, = run_cli("--version")
    explain_status, explanation, = run_cli("explain", spec_path, "--rule", "0")

    expect(version_status).to eq(0)
    expect(version).to eq("#{Flexr::VERSION}\n")
    expect(explain_status).to eq(0)
    expect(explanation).to include("rule 0:")
  end
end
