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

  def random_unicode_string(random, max_codepoints: 8)
    codepoints = Array.new(random.rand(max_codepoints + 1)) do
      loop do
        codepoint = random.rand(0x11_0000)
        break codepoint unless codepoint.between?(0xd800, 0xdfff)
      end
    end
    codepoints.pack("U*")
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
    unicode_inputs = ["", "a", "あ", "é", "ß", "Ω", "١", "　", "aあ", "éΩ", [0x18db8].pack("U")].freeze
    compiled = {}
    cases.times do
      pattern = patterns[random.rand(patterns.length)]
      input = if random.rand(3).zero?
        random.rand(2).zero? ? unicode_inputs.sample(random: random) : FlexrVerification.random_unicode_string(random)
      else
        Array.new(random.rand(10)) { random.rand(32..126) }.pack("C*")
      end
      expected = if Flexr.reference_pattern?(pattern)
        reference = Flexr::Unicode::ReferenceRegexp.compiled(
          pattern, encoding: pattern.encoding, options: pattern.options, unicode: false
        )
        match = reference.match(input, 0)
        if match
          match.begin(0).zero? && match[0].bytesize == input.bytesize
        else
          false
        end
      else
        Regexp.new("\\A(?:#{pattern.source})\\z", pattern.options).match?(input)
      end
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
    runtime_lexer = FlexrVerification.load_runtime(spec)
    parts = runtime_lexer.name.split("::")
    parent = Object
    parts[0...-1].each { |part| parent = parent.const_get(part) }
    parent.send(:remove_const, parts.last) if parent.const_defined?(parts.last, false)
    generated_path = File.join(Dir.tmpdir, "flexr-fuzz-#{Process.pid}-#{File.basename(spec)}")
    before = ObjectSpace.each_object(Class).to_a
    File.binwrite(generated_path, FlexrVerification.generated_source(spec))
    load generated_path
    generated_lexer = (ObjectSpace.each_object(Class).to_a - before).find do |klass|
      klass.respond_to?(:__flexr_spec)
    end
    raise "no generated lexer found for #{spec}" unless generated_lexer

    cases.times do
      input = case random.rand(4)
      when 0
        Array.new(random.rand(128)) { random.rand(0..127) }.pack("C*").force_encoding(Encoding::UTF_8)
      when 1
        FlexrVerification.random_unicode_string(random, max_codepoints: 32)
      when 2
        Array.new(random.rand(128)) { random.rand(0..255) }.pack("C*").force_encoding(Encoding::UTF_8)
      else
        (FlexrVerification.random_unicode_string(random, max_codepoints: 16) +
          Array.new(random.rand(64)) { random.rand(32..126) }.pack("C*")).force_encoding(Encoding::UTF_8)
      end
      runtime_tokens = runtime_lexer.new(input, error_mode: :panic).tokens
      generated_tokens = generated_lexer.new(input, error_mode: :panic).tokens
      next if runtime_tokens == generated_tokens

      abort "fuzz mode mismatch: #{spec} input=#{input.inspect} runtime=#{runtime_tokens.inspect} generated=#{generated_tokens.inspect}"
    rescue Flexr::LexError, ArgumentError, EncodingError
      # Invalid input and user-defined error actions are expected fuzz outcomes.
    end
  ensure
    FileUtils.rm_f(generated_path) if generated_path
  end
  puts "fuzz: #{cases} inputs per example passed"
end

namespace :examples do
  task :check do
    FlexrVerification::EXAMPLES.each do |spec|
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-Ilib", "exe/flexr", "check", spec, "--format", "json", chdir: FlexrVerification::ROOT
      )
      abort "example diagnostics failed for #{spec}: #{stderr}#{stdout}" unless status.success?
      diagnostics = JSON.parse(stdout)
      abort "example diagnostics are not empty for #{spec}: #{diagnostics.inspect}" unless diagnostics.empty?
    rescue JSON::ParserError => e
      abort "example diagnostics were not JSON for #{spec}: #{e.message}\n#{stdout}#{stderr}"
    end
    puts "examples: all checks passed"
  end
end

task :coverage do
  sh RbConfig.ruby, "-Ilib", "tools/coverage.rb"
end

task default: :spec
