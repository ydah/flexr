# frozen_string_literal: true

require "open3"
require "tempfile"
require_relative "../lib/flexr/version"

RSpec.describe "release notes" do
  let(:version) { Flexr::VERSION }

  def run_script(tag, changelog)
    Tempfile.create("flexr-changelog") do |file|
      file.write(changelog)
      file.flush
      script = File.expand_path("../tools/release_notes.rb", __dir__)
      Open3.capture3(RbConfig.ruby, script, tag, file.path)
    end
  end

  it "extracts the tagged version's notes and keeps its subsections" do
    changelog = <<~MARKDOWN
      # Changelog

      ## [Unreleased](https://example.com/unreleased)

      Pending feature.

      ## [#{version}](https://example.com/#{version}) - 2026-11-22

      ### Changed

      - Require Ruby 3.4 or later.

      ## [1.1.0](https://example.com/1.1.0) - 2026-08-12

      Previous release.
    MARKDOWN
    stdout, stderr, status = run_script("v#{version}", changelog)

    expect(status).to be_success, stderr
    expect(stdout).to eq("### Changed\n\n- Require Ruby 3.4 or later.\n")
  end

  it "rejects a tag for a different gem version" do
    _stdout, stderr, status = run_script("v0.0.0", "")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("expected release tag v#{version}")
  end

  it "rejects a changelog without notes for the exact gem version" do
    changelog = "## [#{version}.pre.1](https://example.com/preview)\n\nPreview notes.\n"
    _stdout, stderr, status = run_script("v#{version}", changelog)

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("missing changelog notes for #{version}")
  end
end
