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
require_relative "tools/regexp_tokenizer_reference"

RSpec::Core::RakeTask.new(:spec)
task test: :spec

module FlexrVerification
  ROOT = File.expand_path(__dir__)
  EXAMPLES = Dir[File.join(ROOT, "examples/**/*.flexr.rb")].freeze
  TOKENIZER_SPEC = File.join(ROOT, "lib/flexr/regexp/tokenizer.flexr.rb").freeze
  TOKENIZER_GENERATED = File.join(ROOT, "lib/flexr/regexp/tokenizer.rb").freeze
  VERIFICATION_SPECS = (EXAMPLES + [TOKENIZER_SPEC]).freeze
  EXPECTED_INPUTS = {
    %r{/examples/json/} => '{"answer": 42}',
    %r{/examples/toy_lang/} => "answer + 12",
    %r{/examples/ruby_subset/} => 'class Foo "ok" end',
    %r{/examples/with_racc/} => "12 + 3",
    %r{/examples/with_lrama/} => "12 - 3",
    %r{/lib/flexr/regexp/tokenizer\.flexr\.rb\z} => "a|[a-z]+\\p{L}?"
  }.freeze
  TOKENIZER_REFERENCE_INPUTS = [
    "a|[a-z]+\\p{L}?",
    "あa",
    "aあ",
    "é|あ",
    "\\xffa".b
  ].freeze
  RUNTIME_CLASS_NAMES = {
    %r{/examples/json/} => "JsonExample::Lexer",
    %r{/examples/toy_lang/} => "ToyLang::Lexer",
    %r{/examples/ruby_subset/} => "RubySubset::Lexer",
    %r{/examples/with_racc/} => "WithRacc::RaccLexer",
    %r{/examples/with_lrama/} => "WithLrama::LramaLexer",
    %r{/lib/flexr/regexp/tokenizer\.flexr\.rb\z} => "Flexr::Regexp::SourceLexer"
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
    class_name = runtime_class_name(spec)
    existing = constantize(class_name)
    return existing if runtime_lexer?(existing)
    remove_constant(class_name) if existing

    before = ObjectSpace.each_object(Class).to_a
    load spec
    loaded = (ObjectSpace.each_object(Class).to_a - before).find { |klass| runtime_lexer?(klass) }
    return loaded if loaded

    resolved = constantize(class_name)
    return resolved if runtime_lexer?(resolved)

    raise "no lexer class loaded from #{spec}"
  end

  def runtime_class_name(spec)
    RUNTIME_CLASS_NAMES.find { |pattern, _class_name| spec.match?(pattern) }&.last
  end

  def constantize(class_name)
    return unless class_name

    class_name.split("::").reject(&:empty?).reduce(Object) { |parent, name| parent.const_get(name) }
  rescue NameError
    nil
  end

  def remove_constant(class_name)
    return unless class_name

    parts = class_name.split("::").reject(&:empty?)
    parent = constantize(parts[0...-1].join("::"))
    parent.send(:remove_const, parts.last) if parent&.const_defined?(parts.last, false)
  end

  def runtime_lexer?(klass)
    klass.is_a?(Class) && klass != Flexr::Lexer && klass.respond_to?(:__flexr_spec) &&
      (!klass.respond_to?(:__flexr_generated?) || !klass.__flexr_generated?)
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
      require "json"
      load ARGV.fetch(0)
      lexer = ObjectSpace.each_object(Class).find { |klass| klass.respond_to?(:__flexr_spec) && klass != Flexr::Lexer }
      abort "no generated lexer" unless lexer
      puts JSON.generate(lexer.new(ARGV.fetch(1)).tokens)
    RUBY
    runtime_output, runtime_error, runtime_status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script,
                                                                      spec, input_for(spec))
    generated_output, generated_error, generated_status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script,
                                                                         generated_path, input_for(spec))
    raise "dogfood token mismatch for #{spec}: #{runtime_error}#{generated_error}" unless
      runtime_status.success? && generated_status.success? && runtime_output == generated_output

    return unless spec == TOKENIZER_SPEC

    reference_script = <<~RUBY
      require "json"
      require "regexp_tokenizer_reference"
      puts JSON.generate(FlexrVerification::RegexpTokenizerReference.tokens(ARGV.fetch(0)))
    RUBY
    reference_output, reference_error, reference_status = Open3.capture3(
      RbConfig.ruby, "-Itools", "-e", reference_script, input_for(spec)
    )
    raise "tokenizer reference failed: #{reference_error}" unless reference_status.success?
    raise "tokenizer reference mismatch for #{spec}" unless runtime_output == reference_output
    verify_tokenizer_reference
  ensure
    FileUtils.rm_f(generated_path) if generated_path
  end

  def verify_tokenizer_reference
    runtime_lexer = load_runtime(TOKENIZER_SPEC)
    generated_path = File.join(Dir.tmpdir, "flexr-tokenizer-reference-#{Process.pid}.rb")
    remove_constant("Flexr::Regexp::SourceLexer")
    File.binwrite(generated_path, generated_source(TOKENIZER_SPEC))
    load generated_path
    generated_lexer = Flexr::Regexp.const_get(:SourceLexer, false)

    TOKENIZER_REFERENCE_INPUTS.each do |input|
      expected = RegexpTokenizerReference.tokens(input)
      runtime = runtime_lexer.new(input).tokens
      generated = generated_lexer.new(input).tokens
      next if runtime == expected && generated == expected

      raise "tokenizer reference mismatch for #{input.inspect}: " \
            "runtime=#{runtime.inspect}, generated=#{generated.inspect}, reference=#{expected.inspect}"
    end
  ensure
    FileUtils.rm_f(generated_path) if generated_path
    remove_constant("Flexr::Regexp::SourceLexer")
    Flexr::Regexp.const_set(:SourceLexer, runtime_lexer) if runtime_lexer
  end

end

namespace :modes do
  task :equivalence do
    FlexrVerification::VERIFICATION_SPECS.each do |spec|
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
  FlexrVerification::VERIFICATION_SPECS.each do |spec|
    golden = FlexrVerification.golden_path(spec)
    abort "missing golden file: #{golden}" unless File.file?(golden)

    expected = File.read(golden).strip
    actual = Digest::SHA256.hexdigest(FlexrVerification.generated_source(spec))
    abort "golden mismatch: #{spec} (expected #{expected}, got #{actual})" unless expected == actual
  end
end

task "accel:equivalence" do
  FlexrVerification::VERIFICATION_SPECS.each { |spec| FlexrVerification.verify_acceleration(spec) }
end

task "dogfood:verify" do
  FlexrVerification::VERIFICATION_SPECS.each { |spec| FlexrVerification.verify_dogfood(spec) }
end

task "generated:verify" do
  abort "missing committed tokenizer generated file: #{FlexrVerification::TOKENIZER_GENERATED}" unless
    File.file?(FlexrVerification::TOKENIZER_GENERATED)

  expected = File.binread(FlexrVerification::TOKENIZER_GENERATED)
  actual = FlexrVerification.generated_source(FlexrVerification::TOKENIZER_SPEC)
  abort "committed tokenizer generated file is stale" unless expected == actual

  puts "generated: committed tokenizer is reproducible"
end

task "dot:verify" do
  spec = File.join(FlexrVerification::ROOT, "examples/json/lexer.flexr.rb")
  dot_source, dot_error, dot_status = Open3.capture3(
    RbConfig.ruby, "-Ilib", "exe/flexr", "dot", spec, chdir: FlexrVerification::ROOT
  )
  abort "flexr dot failed: #{dot_error}" unless dot_status.success?

  svg, svg_error, svg_status = Open3.capture3("dot", "-Tsvg", stdin_data: dot_source)
  abort "dot -Tsvg failed: #{svg_error}" unless svg_status.success? && svg.include?("<svg")

  puts "dot: parsed #{spec} as SVG"
rescue Errno::ENOENT => e
  abort "dot executable is required for dot:verify: #{e.message}"
end

task "direct:verify" do
  unless defined?(RubyVM::InstructionSequence)
    puts "direct: disassembly unavailable on #{RUBY_ENGINE}; skipped"
    next
  end

  spec = File.join(FlexrVerification::ROOT, "examples/json/lexer.flexr.rb")
  disassembly = RubyVM::InstructionSequence.compile(FlexrVerification.generated_source(spec)).disasm
  abort "direct dispatch did not compile to opt_case_dispatch" unless disassembly.include?("opt_case_dispatch")

  puts "direct: opt_case_dispatch present"
end

task "unicode:verify" do
  splitter = Flexr::Unicode::Utf8Splitter
  properties = Flexr::Unicode::Data::PROPERTIES
  abort "unexpected vendored Unicode version" unless Flexr::Unicode::VERSION == "15.1.0"
  properties.each do |name, ranges|
    previous = -1
    ranges.each do |lo, hi|
      abort "invalid #{name} Unicode range #{lo.inspect}..#{hi.inspect}" unless
        lo.is_a?(Integer) && hi.is_a?(Integer) && lo <= hi && lo > previous && hi <= 0x10_ffff

      previous = hi
    end
  end
  scalar_count = 0
  (0..0x10_ffff).each do |codepoint|
    next if codepoint.between?(0xd800, 0xdfff)

    expected = [codepoint].pack("U").bytes.map { |byte| [byte, byte] }
    actual = splitter.split(codepoint, codepoint)
    abort "Unicode singleton mismatch at U+#{codepoint.to_s(16)}" unless actual == [expected]
    scalar_count += 1
  end

  random = Random.new(0xF1E2)
  100_000.times do
    loop do
      lo = random.rand(0x11_0000)
      hi = [lo + random.rand(17), 0x10_ffff].min
      next if lo <= 0xdfff && hi >= 0xd800

      sequences = splitter.split(lo, hi)
      abort "Unicode range split was empty for U+#{lo.to_s(16)}..U+#{hi.to_s(16)}" if sequences.empty?
      (lo..hi).each do |codepoint|
        bytes = [codepoint].pack("U").bytes
        included = sequences.any? do |sequence|
          sequence.length == bytes.length && sequence.zip(bytes).all? { |range, byte| byte.between?(*range) }
        end
        abort "Unicode range omitted U+#{codepoint.to_s(16)}" unless included
      end
      break
    end
  end
  puts "unicode: UCD #{Flexr::Unicode::VERSION}, #{properties.length} properties, " \
       "#{scalar_count} singleton and 100000 random range cases passed"
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
  FlexrVerification::VERIFICATION_SPECS.each do |spec|
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
