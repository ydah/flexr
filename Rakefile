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
    %r{/examples/toy_lang/} => "answer + 12",
    %r{/examples/ruby_subset/} => 'class Foo "ok" end',
    %r{/examples/with_racc/} => "12 + 3",
    %r{/examples/with_lrama/} => "12 - 3"
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
    random = Random.new(17)
    inputs = [input_for(spec)] + Array.new(32) do
      Array.new(random.rand(48..96)) { random.rand(32..126) }.pack("C*")
    end
    options = lexer.__flexr_config.options
    original_accel = options.fetch(:accel, :auto)
    accelerated = inputs.map { |input| lexer.new(input, error_mode: :panic).tokens }
    options[:accel] = :none
    reference = inputs.map { |input| lexer.new(input, error_mode: :panic).tokens }
    raise "acceleration token mismatch in #{spec}" unless accelerated == reference

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
  ensure
    options[:accel] = original_accel if options && original_accel
  end

  def verify_dogfood(spec)
    generated_path = File.join(Dir.tmpdir, "flexr-dogfood-#{Process.pid}-#{File.basename(spec)}")
    source = generated_source(spec)
    File.binwrite(generated_path, source)
    _, stderr, status = Open3.capture3(RbConfig.ruby, "-c", generated_path)
    raise "dogfood syntax check failed for #{spec}: #{stderr}" unless status.success?
    raise "generated lexer missing compiled payload: #{spec}" unless source.include?("install_compiled!")
    raise "generated lexer contains an unfinished TODO: #{spec}" if source.include?("FLEXR-TODO")

    script = <<~RUBY
      load ARGV.fetch(0)
      lexer = ObjectSpace.each_object(Class).find { |klass| klass.respond_to?(:__flexr_spec) && klass != Flexr::Lexer }
      abort "no generated lexer" unless lexer
      p lexer.new(ARGV.fetch(1)).tokens
    RUBY
    runtime_output, runtime_error, runtime_status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script,
                                                                      spec, input_for(spec))
    generated_output, generated_error, generated_status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script,
                                                                         generated_path, input_for(spec))
    raise "dogfood token mismatch for #{spec}: #{runtime_error}#{generated_error}" unless
      runtime_status.success? && generated_status.success? && runtime_output == generated_output
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

namespace :test do
  task :differential do
    patterns = [/[a-z]+/, /a(?:b|c)?/, /[0-9]{1,3}/, /[^\n]+/, /foo/,
                /[[:alpha:]]+/, /[[:alnum:]]+/, /\p{L}+/, /\p{Nd}+/]
    cases = Integer(ENV.fetch("FLEXR_DIFFERENTIAL_CASES", "1000000"), 10)
    random = Random.new(Integer(ENV.fetch("FLEXR_SEED", "17"), 10))
    unicode_inputs = ["", "a", "あ", "é", "ß", "Ω", "١", "　", "aあ", "éΩ"].freeze
    compiled = {}
    cases.times do
      pattern = patterns[random.rand(patterns.length)]
      input = if random.rand(4).zero?
        unicode_inputs.sample(random: random)
      else
        Array.new(random.rand(10)) { random.rand(32..126) }.pack("C*")
      end
      expected = Regexp.new("\\A(?:#{pattern.source})\\z", pattern.options).match?(input)
      key = [pattern.source, pattern.options]
      actual = (compiled[key] ||= Flexr.compile_pattern(pattern)).accept?(input)
      next if expected == actual

      abort "differential mismatch: #{pattern.inspect} #{input.inspect} expected=#{expected} actual=#{actual}"
    end
    puts "differential: #{cases} cases passed"
  end
end

task :fuzz do
  cases = Integer(ENV.fetch("FLEXR_FUZZ_CASES", "10000"), 10)
  random = Random.new(Integer(ENV.fetch("FLEXR_SEED", "17"), 10))
  FlexrVerification::EXAMPLES.each do |spec|
    lexer = FlexrVerification.load_runtime(spec)
    cases.times do
      input = Array.new(random.rand(128)) { random.rand(0..127) }.pack("C*").force_encoding(Encoding::UTF_8)
      lexer.new(input, error_mode: :panic).tokens
    rescue Flexr::LexError, ArgumentError
      # Invalid input and user-defined error actions are expected fuzz outcomes.
    end
  end
  puts "fuzz: #{cases} inputs per example passed"
end

task default: :spec
