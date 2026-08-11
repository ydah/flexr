# frozen_string_literal: true

require_relative "lib/flexr/version"

Gem::Specification.new do |spec|
  spec.name = "flexr"
  spec.version = Flexr::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "Ruby-native lexer generator with runtime and generated modes"
  spec.description = "A Ruby DSL and source generator for deterministic byte-oriented lexers."
  spec.homepage = "https://github.com/ydah/flexr"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["generator_ruby_version"] = ">= 3.3 (Prism)"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/ydah/flexr/tree/main"
  spec.metadata["bug_tracker_uri"] = "https://github.com/ydah/flexr/issues"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
