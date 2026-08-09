# Releasing

1. Run `bundle exec rake test && bundle exec rake modes:equivalence`.
2. Run `bundle exec rake golden:verify accel:equivalence dogfood:verify`.
3. Update `CHANGELOG.md` and `lib/flexr/version.rb`.
4. Build and inspect the gem with `gem build flexr.gemspec`.
5. Create the release tag after the working tree is clean.
