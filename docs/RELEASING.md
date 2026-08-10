# Releasing

1. Run `bundle exec rake test && bundle exec rake modes:equivalence`.
2. Run `bundle exec rake generated:verify golden:verify accel:equivalence dogfood:verify`.
3. Run `bundle exec rake unicode:verify dot:verify`; `dot:verify` requires Graphviz.
4. Run `bundle exec rake bench:regression`; a missing or stale baseline is a
  release failure, not a skipped check.
5. Update `CHANGELOG.md` and `lib/flexr/version.rb`.
6. Build and inspect the gem with `gem build flexr.gemspec`.
7. Create the release tag after the working tree is clean.
