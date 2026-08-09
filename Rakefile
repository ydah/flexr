# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "fileutils"
require "tmpdir"
require "open3"
require "flexr"

RSpec::Core::RakeTask.new(:spec)

task test: :spec

namespace :modes do
  task :equivalence do
    Dir["examples/**/*.flexr.rb"].each do |spec|
      generated = File.join(Dir.tmpdir, "flexr-#{File.basename(spec)}")
      Flexr::Generator.new(spec, output: generated).generate
      source = spec.include?("json") ? '{"answer": 42}' : 'answer + 12'
      script = <<~RUBY
        load ARGV.fetch(0)
        lexer = ObjectSpace.each_object(Class).find { |klass| klass.respond_to?(:__flexr_spec) && klass != Flexr::Lexer }
        abort "no lexer found" unless lexer
        p lexer.new(ARGV.fetch(1)).tokens
      RUBY
      runtime_output, = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script, spec, source)
      generated_output, = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script, generated, source)
      abort "mode mismatch: #{spec}" unless runtime_output == generated_output
    ensure
      FileUtils.rm_f(generated) if generated
    end
  end
end

task "golden:verify" => "modes:equivalence"
task "accel:equivalence" => "modes:equivalence"
task "dogfood:verify" => "modes:equivalence"
task "bench:regression" do
  puts "benchmark regression: no baseline corpus configured"
end

task default: :spec
