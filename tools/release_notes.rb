# frozen_string_literal: true

require_relative "../lib/flexr/version"

version = Flexr::VERSION
tag = ARGV.first
abort "expected release tag v#{version}, got #{tag.inspect}" unless tag == "v#{version}"

path = ARGV.fetch(1) { File.expand_path("../CHANGELOG.md", __dir__) }
heading = "## [#{version}]("
section = File.read(path).split(/(?=^## )/).find { |entry| entry.start_with?(heading) }
notes = section.to_s.lines.drop(1).join.strip
abort "missing changelog notes for #{version}" if notes.empty?

puts notes
