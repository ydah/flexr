# Releasing

1. Run `bundle exec rake test && bundle exec rake modes:equivalence`.
2. Run `bundle exec rake golden:verify accel:equivalence dogfood:verify`.
3. Run `bundle exec rake bench:regression`; a missing or stale baseline is a
   release failure, not a skipped check.
4. Update `CHANGELOG.md` and `lib/flexr/version.rb`.
5. Build and inspect the gem with `gem build flexr.gemspec`.
6. Create the release tag after the working tree is clean.
