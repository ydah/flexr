# Compatibility

## Ruby and dependencies

| Surface | Requirement |
|---|---|
| Runtime gem | Ruby 3.1+ |
| Generator | Ruby 3.3+ with Prism available |
| Standalone runtime | Compatible Ruby plus the generated file |
| Optional acceleration | Ruby `strscan` when available; regexp fallback remains valid |

Runtime mode does not require Prism. Generated mode uses Prism only while
reading the source; normal generated output does not need the generator.

## Matching and encoding

UTF-8 and binary are the supported specification encodings. The automaton is
byte-oriented, but UTF-8 boundaries and Unicode properties are validated using
the vendored data snapshot. Invalid UTF-8 is not silently repaired.

## Unicode snapshot

The current Unicode Character Database snapshot is 15.1.0. It supplies Unicode
properties, POSIX behavior where applicable, Unicode shorthand behavior under
`option :unicode`, and case folding. Updating the snapshot can change generated
output and is therefore a minor-version compatibility change. Run
`bundle exec rake unicode:verify` and regenerate golden artifacts after an
update.

## Generated files and SemVer

Runtime and generated-file compatibility is preserved within a major version
unless a migration is explicitly documented. Generated artifacts include a
payload digest and Unicode version so stale or cross-version output can be
detected. Do not assume that internal table layouts are stable.

Stable backends are `table`, `direct`, and `auto`. `firstmatch` is experimental
and does not share the longest-match promise.
