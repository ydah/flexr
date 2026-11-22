# Releasing

Run these checks from a clean checkout on the target Ruby versions before
pushing a release tag:

```sh
bundle exec rake test
bundle exec rubocop
bundle exec rake docs:verify
bundle exec rake modes:equivalence golden:verify accel:equivalence dogfood:verify
bundle exec rake generated:verify unicode:verify examples:check
bundle exec rake test:differential fuzz
bundle exec rake bench:regression
```

`dot:verify` is required when Graphviz is available. It parses the generated DOT
output as SVG and should be run before a release that changes CLI visualization.

Then:

1. Review the commits since the previous release, add a dated version section
   to [the changelog](../CHANGELOG.md), and update `lib/flexr/version.rb`.
2. Verify the gemspec metadata URLs.
3. Build and inspect the package with `gem build flexr.gemspec`.
4. Confirm generated golden files and the Unicode snapshot are intentional.
5. Create the release tag only after the working tree and CI are clean.

Pushing a tag such as `v2.1.0` starts the release workflow. The tag must match
`lib/flexr/version.rb` and have a corresponding numbered changelog section.
The workflow runs the checks on Ruby 3.4 and 4.0, publishes the gem with
RubyGems Trusted Publishing, then creates the GitHub Release from that
changelog section. Prerelease tags create GitHub prereleases.

The hosted benchmark uses the portable gate because shared runner speed
varies. Run the local benchmark command above on the reference machine to
check the absolute throughput floor before publishing. If the GitHub Release
step fails after the gem is published, rerun the failed jobs.

Unicode snapshot changes are minor-version compatibility changes because they
can change generated output. Stable runtime and generated-file contracts are
preserved within a major version unless this document and the changelog
state a migration.
