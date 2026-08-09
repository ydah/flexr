# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"

require_relative "../benchmark/run"

RSpec.describe "verification tooling" do
  ROOT = File.expand_path("..", __dir__)

  it "keeps golden, acceleration, and dogfood gates independent" do
    script = <<~RUBY
      require "rake"
      load "Rakefile"
      %w[golden:verify accel:equivalence dogfood:verify].each do |name|
        puts "\#{name}:\#{Rake::Task[name].prerequisites.inspect}"
      end
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: ROOT)

    expect(status).to be_success, stderr
    expect(stdout).to include("golden:verify:[]", "accel:equivalence:[]", "dogfood:verify:[]")
  end

  it "passes the independent verification gates" do
    %w[golden:verify accel:equivalence dogfood:verify].each do |name|
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-S", "rake", name, chdir: ROOT)
      expect(status).to be_success, "#{name} failed: #{stderr}"
    end
  end

  it "fails benchmark verification when its baseline is missing" do
    missing = File.join(Dir.tmpdir, "flexr-missing-baseline-#{Process.pid}.json")
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "benchmark/run.rb",
                                             "--baseline", missing, "--json", chdir: ROOT)

    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("baseline is missing or invalid")
  end

  it "rejects a baseline for changed input identity" do
    baseline = JSON.parse(File.read(File.join(ROOT, "benchmark/baselines/json.json")))
    baseline["source_sha256"] = "changed"
    Tempfile.create(["flexr-baseline-", ".json"]) do |file|
      file.write(JSON.generate(baseline))
      file.flush
      result = baseline.merge("source_sha256" => "current")
      expect(Flexr::Benchmarking::Baseline.check(file.path, result, threshold: 0.1)).to eq(1)
    end
  end
end
