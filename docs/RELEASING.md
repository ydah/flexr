# Releasing

The release process validates both implementation and user-facing contracts.
Run these commands from a clean checkout on the target Ruby versions:

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

1. Review the commits since the previous release, add a version section
   to [the changelog](../CHANGELOG.md), and update `lib/flexr/version.rb`.
2. Verify the gemspec metadata URLs.
3. Build and inspect the package with `gem build flexr.gemspec`.
4. Confirm generated golden files and the Unicode snapshot are intentional.
5. Create the release tag only after the working tree and CI are clean.

Pushing a v1 tag runs the release checks before building and publishing the
gem through RubyGems Trusted Publishing. The workflow then creates a GitHub
Release from that version's changelog, leaving the latest major release
selected on GitHub. Use the version number as the level-two changelog heading,
optionally linked to the tag comparison. GitHub records the publication date.

Unicode snapshot changes are minor-version compatibility changes because they
can change generated output. Stable runtime and generated-file contracts are
preserved within a major version unless this document and the changelog
state a migration.
