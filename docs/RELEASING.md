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

1. Move the intended entries from `Unreleased` into a dated version section in
   `CHANGELOG.md`.
2. Update `lib/flexr/version.rb` and verify the gemspec metadata URLs.
3. Build and inspect the package with `gem build flexr.gemspec`.
4. Confirm generated golden files and the Unicode snapshot are intentional.
5. Create the release tag only after the working tree and CI are clean.

Unicode snapshot changes are minor-version compatibility changes because they
can change generated output. Stable runtime and generated-file contracts are
preserved within a major version unless this document and the changelog state a
migration.
