# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tempfile"

RSpec.describe "feature cost benchmark" do
  def measure(*options)
    Open3.capture3(RbConfig.ruby, "-Ilib", "benchmark/feature_costs.rb",
                   "--iterations", "1", "--repeats", "3", *options,
                   chdir: File.expand_path("..", __dir__))
  end

  it "measures active and unused cases with matching outputs in both scanner modes" do
    stdout, stderr, status = measure
    expect(status).to be_success, stderr
    features = JSON.parse(stdout).fetch("features")
    expect(features.keys).to contain_exactly(
      "captures", "channels", "expect", "keywords", "priority", "pattern_algebra", "delegation", "indentation", "push_input"
    )
    features.each_value do |result|
      expect(result.fetch("parity_verified")).to be(true)
      %w[with without].each do |variant|
        measurement = result.fetch(variant)
        expect(measurement.fetch("runtime").fetch("bytes_per_second")).to be_positive
        expect(measurement.fetch("generated").fetch("bytes_per_second")).to be_positive
        expect(measurement.fetch("runtime").fetch("prepare_seconds")).to be_positive
        expect(measurement.fetch("generated").fetch("prepare_seconds")).to be_positive
      end
    end
  end

  it "reports the unused scanner that regressed against a compatible baseline" do
    stdout, stderr, status = measure
    expect(status).to be_success, stderr
    baseline = JSON.parse(stdout)
    baseline.fetch("features").each_value do |result|
      result.fetch("without").each_value { |row| row["bytes_per_second"] /= 1000 }
    end
    baseline.fetch("features").fetch("captures").fetch("without").fetch("generated")["bytes_per_second"] = 1e20

    Tempfile.create(["feature-costs-", ".json"]) do |file|
      file.write(JSON.generate(baseline))
      file.flush
      stdout, stderr, status = measure("--baseline", file.path)
      expect(status.exitstatus).to eq(1), stderr
      failures = JSON.parse(stdout).fetch("unused_regression_check").fetch("failures")
      expect(failures).to match([a_hash_including("feature" => "captures", "mode" => "generated")])
    end
  end
end
