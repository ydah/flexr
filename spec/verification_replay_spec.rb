# frozen_string_literal: true

require "digest"
require "json"
require "open3"

RSpec.describe "verification failure replay" do
  let(:root) { File.expand_path("..", __dir__) }

  def run_task(task, env, mutation = "")
    script = <<~RUBY
      require "rake"
      load "Rakefile"
      #{mutation}
      Rake::Task[ARGV.fetch(0)].invoke
    RUBY
    Open3.capture3(env, RbConfig.ruby, "-e", script, task, chdir: root)
  end

  it "saves a differential mismatch and compares the recorded case against the current compiler" do
    mutation = <<~RUBY
      module InvertAcceptance
        def compile_pattern(...)
          compiled = super
          Object.new.tap do |dfa|
            dfa.define_singleton_method(:accept?) { |input| !compiled.accept?(input) }
          end
        end
      end
      Flexr.singleton_class.prepend(InvertAcceptance)
    RUBY

    Dir.mktmpdir do |dir|
      env = { "FLEXR_FAILURE_DIR" => dir, "FLEXR_DIFFERENTIAL_CASES" => "20", "FLEXR_SEED" => "17" }
      _stdout, stderr, status = run_task("test:differential", env, mutation)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("differential mismatch:")
      paths = Dir.glob(File.join(dir, "*.json"))
      expect(paths.size).to eq(1)
      path = paths.first
      expect(stderr).to include("verification:replay", path)

      failure = JSON.parse(File.read(path))
      expect(failure).to include("task" => "test:differential", "seed" => 17)
      expect(failure.fetch("case")).to be_between(1, 20)
      expect(failure.fetch("pattern")).to include("source", "options", "encoding")
      expect(failure.fetch("expected")).not_to eq(failure.fetch("actual"))

      replay_env = env.merge("FLEXR_FAILURE_CASE" => path, "FLEXR_DIFFERENTIAL_CASES" => "0",
                             "FLEXR_SEED" => "invalid")
      _stdout, replay_error, replay_status = run_task("verification:replay", replay_env, mutation)
      expect(replay_status.exitstatus).to eq(1)
      expect(replay_error.lines).to include(stderr.lines.first)
      expect(Dir.glob(File.join(dir, "*.json"))).to eq([path])

      stdout, stderr, status = run_task("verification:replay", replay_env)
      expect(status).to be_success, stderr
      expect(stdout).to include("test:differential", "passed")
    end
  end

  it "preserves the global case number and bytes for a fuzz mismatch in a shard" do
    mutation = <<~RUBY
      module DivergeOnInvalidUTF8
        def lexer_outcome(lexer, input, **)
          if lexer.__flexr_generated? && input.encoding == Encoding::UTF_8 && !input.valid_encoding?
            { kind: :tokens, tokens: [[:INVALID, input]] }
          else
            super
          end
        end
      end
      FlexrVerification.singleton_class.prepend(DivergeOnInvalidUTF8)
    RUBY

    Dir.mktmpdir do |dir|
      env = {
        "FLEXR_FAILURE_DIR" => dir, "FLEXR_FUZZ_CASES" => "100", "FLEXR_SEED" => "17", "FLEXR_FUZZ_SHARD" => "2/3"
      }
      _stdout, stderr, status = run_task("fuzz", env, mutation)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("fuzz mode mismatch:")
      paths = Dir.glob(File.join(dir, "*.json"))
      expect(paths.size).to eq(1)
      path = paths.first
      failure = JSON.parse(File.read(path))
      expect(failure).to include("task" => "fuzz", "seed" => 17, "options" => { "error_mode" => "panic" })
      expect((failure.fetch("case") - 1) % 3).to eq(2)
      spec = failure.fetch("spec")
      expect(spec.fetch("sha256")).to eq(Digest::SHA256.file(File.join(root, spec.fetch("path"))).hexdigest)
      expect(failure.fetch("backends")).to include("runtime", "generated")
      input = failure.fetch("input")
      expect(input.fetch("encoding")).to eq("UTF-8")
      expect([input.fetch("hex")].pack("H*").force_encoding("UTF-8")).not_to be_valid_encoding
      expect(failure.dig("actual", "tokens", 0, 1)).to eq(input)

      replay_env = env.merge("FLEXR_FAILURE_CASE" => path, "FLEXR_FUZZ_CASES" => "0", "FLEXR_SEED" => "invalid")
      _stdout, replay_error, replay_status = run_task("verification:replay", replay_env, mutation)
      expect(replay_status.exitstatus).to eq(1)
      expect(replay_error.lines).to include(stderr.lines.first)

      stdout, stderr, status = run_task("verification:replay", replay_env)
      expect(status).to be_success, stderr
      expect(stdout).to include("fuzz", "passed")
    end
  end

  it "rejects an out-of-range fuzz shard" do
    _stdout, stderr, status = run_task("fuzz", "FLEXR_FUZZ_SHARD" => "3/3", "FLEXR_FUZZ_CASES" => "0")
    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("FLEXR_FUZZ_SHARD must be INDEX/TOTAL")
  end
end
