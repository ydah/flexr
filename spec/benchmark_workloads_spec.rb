# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require_relative "../benchmark/matrix"

RSpec.describe "benchmark workloads" do
  def benchmark(specification, *options, environment: {})
    Dir.mktmpdir do |directory|
      spec_path = File.join(directory, "lexer.flexr.rb")
      input_path = File.join(directory, "input.txt")
      File.binwrite(spec_path, specification)
      File.binwrite(input_path, "alpha\nbeta\n")
      Open3.capture3(environment, RbConfig.ruby, "benchmark/run.rb", "--spec", spec_path,
                     "--input-file", input_path, "--iterations", "1", "--json", *options,
                     chdir: File.expand_path("..", __dir__))
    end
  end

  it "benchmarks identical bytes in both requested input modes and checks all scanner modes" do
    specification = <<~'RUBY'
      class WorkloadLexer < Flexr::Lexer
        rule(/[a-z]+/, emit: :WORD)
        rule(/\s+/, skip: true)

        def initialize(input, **options)
          frozen_input = ENV.fetch("FLEXR_TEST_WORKLOAD_INPUT_MODE") == "frozen"
          raise "unexpected input mode" unless input.frozen? == frozen_input

          super
        end
      end
    RUBY
    %w[frozen mutable].each do |mode|
      environment = { "FLEXR_TEST_WORKLOAD_INPUT_MODE" => mode }
      output, errors, status = benchmark(specification, "--input-mode", mode, "--verify-parity", environment: environment)
      expect(status).to be_success, errors
      expect(JSON.parse(output)).to include(
        "input_mode" => mode, "parity_verified" => true, "tokens" => 2,
        "input_sha256" => Digest::SHA256.hexdigest("alpha\nbeta\n")
      )
    end
  end

  it "rejects different standalone token values even when the token count agrees" do
    specification = <<~'RUBY'
      class WorkloadLexer < Flexr::Lexer
        rule(/[a-z]+/) { emit :WORD, defined?(Flexr::Source) ? text : text.upcase }
        rule(/\s+/, skip: true)
      end
    RUBY
    output, errors, status = benchmark(specification, "--verify-parity")
    expect(status.exitstatus).to eq(1), errors
    expect(output).to be_empty
    expect(errors).to match(/standalone/i).and match(/parity|token/i)
  end

  it "ignores reference sharing when the lexer emits the same token values" do
    specification = <<~'RUBY'
      class WorkloadLexer < Flexr::Lexer
        rule(/[a-z]+/) do
          emit :WORD, defined?(Flexr::Source) ? (@shared_value ||= +"value") : +"value"
        end
        rule(/\s+/, skip: true)
      end
    RUBY
    output, errors, status = benchmark(specification, "--verify-parity")
    expect(status).to be_success, errors
    expect(JSON.parse(output)).to include("parity_verified" => true)
  end

  it "only compares baselines for the recorded input mode" do
    baseline = { "input_sha256" => "same-bytes", "input_mode" => "frozen" }
    result = baseline.merge("input_mode" => "mutable")

    expect(Flexr::Benchmarking::Baseline.identity_matches?(baseline, result)).to be(false)
    expect(Flexr::Benchmarking::Baseline.identity_matches?({ "input_sha256" => "same-bytes" }, result)).to be(true)
  end

  it "measures both input modes for each corpus and reports each failed engine cell" do
    calls = []
    matrix = Class.new do
      define_method(:initialize) { |arguments:| @arguments = arguments }

      define_method(:run) do |verify_ratio:, engines: %w[interpreter yjit zjit]|
        spec = @arguments.fetch(@arguments.index("--spec") + 1)
        workload = File.basename(File.dirname(spec))
        input_mode = @arguments.fetch(@arguments.index("--input-mode") + 1)
        calls << [workload, input_mode, engines, verify_ratio, @arguments]
        failed_engines = {
          %w[sql mutable] => ["yjit"], %w[ruby_subset frozen] => ["zjit"]
        }.fetch([workload, input_mode], [])
        measurements = engines.to_h do |engine|
          ratio = failed_engines.include?(engine) ? 0.9 : 1.1
          [engine, { "median_generated_runtime_ratio" => ratio, "ratio_samples" => [ratio, ratio, ratio] }]
        end
        {
          "schema" => 1, "engines" => measurements,
          "generated_runtime_ratio_check" => { "minimum" => 1.0, "passed" => failed_engines.empty?, "failed_engines" => failed_engines }
        }
      end
    end

    report = Flexr::Benchmarking::RubyMatrix.run_workloads(arguments: %w[--iterations 2], verify_ratio: true, matrix: matrix)
    workloads = %w[json toml graphql sql ruby_subset]
    expect(calls.map { |workload, input_mode, *| [workload, input_mode] }).to match_array(workloads.product(%w[frozen mutable]))
    calls.each do |_, _, engines, verify_ratio, arguments|
      expect(engines).to eq(%w[interpreter yjit zjit])
      expect(verify_ratio).to be(true)
      expect(arguments).to include("--iterations", "2", "--verify-parity")
    end
    expect(report.fetch("workloads").fetch("json").fetch("frozen").fetch("engines").fetch("interpreter")).to include(
      "median_generated_runtime_ratio" => 1.1, "ratio_samples" => [1.1, 1.1, 1.1]
    )
    expect(report.fetch("generated_runtime_ratio_check")).to include("minimum" => 1.0, "passed" => false)
    expect(report.fetch("generated_runtime_ratio_check").fetch("failed_cells")).to contain_exactly(
      { "workload" => "sql", "input_mode" => "mutable", "engine" => "yjit" },
      { "workload" => "ruby_subset", "input_mode" => "frozen", "engine" => "zjit" }
    )
  end

  it "rejects a custom input file before running the workload matrix" do
    output = StringIO.new
    errors = StringIO.new
    expect(Flexr::Benchmarking::RubyMatrix).not_to receive(:run_workloads)

    status = Flexr::Benchmarking::RubyMatrix.command(%w[--workloads --input-file input.txt], out: output, err: errors)
    expect(status).to eq(2)
    expect(output.string).to be_empty
    expect(errors.string).to include("--workloads", "--input-file")
  end
end
