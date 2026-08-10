# Releasing

1. Run `bundle exec rake test && bundle exec rake modes:equivalence`.
2. Run `bundle exec rake generated:verify golden:verify accel:equivalence dogfood:verify`.
3. Run `bundle exec rake unicode:verify dot:verify`; `dot:verify` requires Graphviz.
4. Run `bundle exec rake test:differential fuzz`; the full deterministic
   differential and generated/runtime fuzz gates must pass.
5. Run `bundle exec rake bench:regression`; a missing or stale baseline is a
  release failure, not a skipped check.
6. Update `CHANGELOG.md` and `lib/flexr/version.rb`.
7. Build and inspect the gem with `gem build flexr.gemspec`.
8. Create the release tag after the working tree is clean.
