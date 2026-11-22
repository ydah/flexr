# frozen_string_literal: true

require "json"
require "open3"
require "stringio"
require_relative "../benchmark/profile"
require_relative "../benchmark/matrix"

RSpec.describe "benchmark profiling" do
  it "attributes scanning, actions, token construction, and locations without changing tokens" do
    lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/[a-z]+/) { emit :WORD }
      rule(/ +/, skip: true)
    end
    lexer.new("hello world").tokens
    profiler = Flexr::Benchmarking::PhaseProfiler.new
    tokens = profiler.measure { lexer.new("hello world").tokens }

    expect(tokens.map(&:value)).to eq(%w[hello world])
    expect(profiler.seconds.keys).to match_array(%w[scanning actions tokens locations other])
    expect(profiler.seconds.values).to all(be >= 0)
    expect(profiler.seconds.fetch("scanning")).to be > 0
    expect(profiler.seconds.fetch("actions")).to be > 0
    expect(profiler.seconds.fetch("tokens")).to be > 0
    expect(profiler.seconds.fetch("locations")).to be > 0
    expect(profiler.seconds.values.sum).to be_within(0.001).of(profiler.elapsed)
  end

  it "disables instrumentation when a measured action raises" do
    profiler = Flexr::Benchmarking::PhaseProfiler.new
    expect { profiler.measure { raise ArgumentError, "action failed" } }.to raise_error(ArgumentError, "action failed")
    expect(profiler.enabled?).to be(false)
  end

  it "runs the profile command against both lexer modes" do
    Dir.mktmpdir do |directory|
      input = File.join(directory, "input.json")
      File.write(input, '{"answer":42}')
      output, errors, status = Open3.capture3(RbConfig.ruby, "benchmark/profile.rb", "--input-file", input,
                                             "--iterations", "1", chdir: File.expand_path("..", __dir__))
      expect(status).to be_success, errors
      result = JSON.parse(output)
      expect(result.fetch("modes").keys).to eq(%w[runtime generated])
      result.fetch("modes").each_value do |mode|
        expect(mode.fetch("tokens")).to eq(5)
        expect(mode.fetch("phase_seconds").keys).to include("scanning", "actions", "tokens", "locations")
      end
    end
  end

  it "reports unavailable engines explicitly and propagates benchmark failures" do
    available = { "interpreter" => { "available" => true }, "yjit" => { "available" => false, "reason" => "not built" } }
    calls = []
    runner = Flexr::Benchmarking::RubyMatrix.new(probe: ->(engine) { available.fetch(engine) },
                                               benchmark: lambda { |engine|
                                                 calls << engine
                                                 { "tokens" => 5 }
                                               })
    result = runner.run(engines: %w[interpreter yjit])
    expect(calls).to eq(["interpreter"])
    expect(result.fetch("engines").fetch("yjit")).to include("status" => "unavailable", "reason" => "not built")
    expect(result.fetch("engines").fetch("interpreter")).to include("status" => "measured", "result" => { "tokens" => 5 })
    runner = Flexr::Benchmarking::RubyMatrix.new(probe: ->(_engine) { { "available" => true } },
                                               benchmark: ->(_engine) { raise "benchmark failed" })
    expect { runner.run(engines: ["interpreter"]) }.to raise_error("benchmark failed")
  end

  it "checks the median generated/runtime ratio and requires every engine" do
    generated_rates = { "interpreter" => [102, 103, 104], "yjit" => [97, 103, 101], "zjit" => [99, 98, 103] }
    benchmark = lambda do |engine|
      {
        "modes" => {
          "runtime" => { "tokens_per_s" => 100 },
          "generated" => { "tokens_per_s" => generated_rates.fetch(engine).shift }
        }
      }
    end
    runner = Flexr::Benchmarking::RubyMatrix.new(probe: ->(_engine) { { "available" => true } }, benchmark: benchmark)
    result = runner.run(verify_ratio: true)
    expect(result.fetch("engines").fetch("yjit")).to include(
      "ratio_samples" => [0.97, 1.03, 1.01], "median_generated_runtime_ratio" => 1.01
    )
    expect(result.fetch("generated_runtime_ratio_check")).to include("passed" => false, "failed_engines" => ["zjit"])

    unavailable = ->(_engine) { { "available" => false, "reason" => "not built" } }
    missing = Flexr::Benchmarking::RubyMatrix.new(probe: unavailable, benchmark: benchmark).run(verify_ratio: true)
    expect(missing.fetch("generated_runtime_ratio_check").fetch("failed_engines")).to eq(%w[interpreter yjit zjit])
  end

  it "rejects invalid iteration counts before starting subprocesses" do
    errors = StringIO.new
    expect(Flexr::Benchmarking::RubyMatrix.command(["--iterations", "0"], out: StringIO.new, err: errors)).to eq(2)
    expect(errors.string).to include("iterations must be positive")
  end

  it "runs the interpreter probe and benchmark in separate Ruby processes" do
    Dir.mktmpdir do |directory|
      input = File.join(directory, "input.json")
      File.write(input, '{"answer":42}')
      script = File.join(directory, "matrix_check.rb")
      File.write(script, <<~RUBY)
        require #{File.expand_path('../benchmark/matrix', __dir__).inspect}
        result = Flexr::Benchmarking::RubyMatrix.new(arguments: ARGV).run(engines: ["interpreter"])
        puts JSON.generate(result)
      RUBY
      output, errors, status = Open3.capture3(RbConfig.ruby, script, "--input-file", input,
                                             "--iterations", "1", chdir: File.expand_path("..", __dir__))
      expect(status).to be_success, errors
      result = JSON.parse(output).fetch("engines").fetch("interpreter")
      expect(result.fetch("status")).to eq("measured")
      expect(result.fetch("result").fetch("tokens")).to eq(5)
    end
  end

  it "rejects a shared baseline output file for matrix runs" do
    errors = StringIO.new
    expect(Flexr::Benchmarking::RubyMatrix.command(["--write-baseline", "baseline.json"], out: StringIO.new, err: errors)).to eq(2)
    expect(errors.string).to include("cannot share a baseline output file")
  end
end
