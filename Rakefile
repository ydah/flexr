# frozen_string_literal: true

require "bundler/gem_tasks"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "rspec/core/rake_task"
require "tmpdir"
require "flexr"

RSpec::Core::RakeTask.new(:spec)
task test: :spec

module FlexrVerification
  ROOT = File.expand_path(__dir__)
  EXAMPLES = Dir[File.join(ROOT, "examples/**/*.flexr.rb")].freeze
  EXPECTED_INPUTS = {
    %r{/examples/json/} => '{"answer": 42}',
    %r{/examples/toy_lang/} => "answer + 12"
  }.freeze
  module_function

  def input_for(spec)
    EXPECTED_INPUTS.find { |pattern, _| spec.match?(pattern) }&.last || raise("no verification input for #{spec}")
  end

  def golden_path(spec)
    name = "#{File.basename(File.dirname(spec))}_#{File.basename(spec, '.flexr.rb')}.sha256"
    File.join(ROOT, "benchmark/golden", name)
  end

  def generated_source(spec)
    Flexr::Generator.new(relative_spec(spec)).generate
  end

  def relative_spec(spec)
    spec.delete_prefix("#{ROOT}/")
  end

  def load_runtime(spec)
    before = ObjectSpace.each_object(Class).to_a
    load spec
    (ObjectSpace.each_object(Class).to_a - before).find { |klass| klass.respond_to?(:__flexr_spec) } ||
      raise("no lexer class loaded from #{spec}")
  end

  def verify_acceleration(spec)
    lexer = load_runtime(spec)
    lexer.compile!.machines.each_value do |machine|
      Flexr::Automaton::Accel.extract(machine.dfa).each do |region|
        256.times do |byte|
          expected = region.bytes.include?(byte)
          actual = region.regexp.match?(byte.chr(Encoding::BINARY))
          next if expected == actual

          raise "acceleration mismatch in #{spec}: state=#{region.state}, byte=#{byte}"
        end
      end
    end
  end

  def verify_dogfood(spec)
    generated_path = File.join(Dir.tmpdir, "flexr-dogfood-#{Process.pid}-#{File.basename(spec)}")
    source = generated_source(spec)
    File.binwrite(generated_path, source)
    _, stderr, status = Open3.capture3(RbConfig.ruby, "-c", generated_path)
    raise "dogfood syntax check failed for #{spec}: #{stderr}" unless status.success?
    raise "generated lexer missing compiled payload: #{spec}" unless source.include?("install_compiled!")
    raise "generated lexer contains an unfinished TODO: #{spec}" if source.include?("FLEXR-TODO")
  ensure
    FileUtils.rm_f(generated_path) if generated_path
  end

end

namespace :modes do
  task :equivalence do
    FlexrVerification::EXAMPLES.each do |spec|
      generated_path = File.join(Dir.tmpdir, "flexr-mode-#{Process.pid}-#{File.basename(spec)}")
      File.binwrite(generated_path, FlexrVerification.generated_source(spec))
      script = <<~RUBY
        load ARGV.fetch(0)
        lexer = ObjectSpace.each_object(Class).find { |klass| klass.respond_to?(:__flexr_spec) && klass != Flexr::Lexer }
        abort "no lexer found" unless lexer
        p lexer.new(ARGV.fetch(1)).tokens
      RUBY
      runtime_output, runtime_error, runtime_status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script,
                                                                       spec, FlexrVerification.input_for(spec))
      generated_output, generated_error, generated_status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script,
                                                                            generated_path, FlexrVerification.input_for(spec))
      abort "mode mismatch: #{spec}\n#{runtime_error}#{generated_error}" unless runtime_status.success? && generated_status.success? && runtime_output == generated_output
    ensure
      FileUtils.rm_f(generated_path) if generated_path
    end
  end
end

task "golden:verify" do
  FlexrVerification::EXAMPLES.each do |spec|
    golden = FlexrVerification.golden_path(spec)
    abort "missing golden file: #{golden}" unless File.file?(golden)

    expected = File.read(golden).strip
    actual = Digest::SHA256.hexdigest(FlexrVerification.generated_source(spec))
    abort "golden mismatch: #{spec} (expected #{expected}, got #{actual})" unless expected == actual
  end
end

task "accel:equivalence" do
  FlexrVerification::EXAMPLES.each { |spec| FlexrVerification.verify_acceleration(spec) }
end

task "dogfood:verify" do
  FlexrVerification::EXAMPLES.each { |spec| FlexrVerification.verify_dogfood(spec) }
end

task "bench:regression" do
  baseline = ENV.fetch("FLEXR_BENCHMARK_BASELINE", File.join(FlexrVerification::ROOT, "benchmark/baselines/json.json"))
  command = [RbConfig.ruby, "-Ilib", "benchmark/run.rb", "--baseline", baseline, "--json"]
  stdout, stderr, status = Open3.capture3(*command, chdir: FlexrVerification::ROOT)
  abort "benchmark regression failed (#{status.exitstatus}): #{stderr}#{stdout}" unless status.success?

  puts stdout
end

task default: :spec
