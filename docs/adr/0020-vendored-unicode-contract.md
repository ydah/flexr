# ADR 0020: Vendored Unicode is the compatibility contract

## Context

Ruby's `Regexp` Unicode tables are supplied by the host runtime and can change
between Ruby releases. A lexer generated with the same flexr source must not
change merely because it was built on another Ruby version. The repository
therefore vendors a Unicode Character Database snapshot.

## Decision

The vendored Unicode Character Database, currently version `15.1.0`, is the
oracle for `\p{...}`, POSIX properties, Unicode shorthands under
`option :unicode`, and case folding. Host Ruby `Regexp` is not used as a
cross-version property oracle. Updating the snapshot is a minor-version
compatibility change and must regenerate golden outputs.

`rake unicode:verify` checks the snapshot version, range invariants, all scalar
singleton UTF-8 expansions, and 100,000 deterministic random ranges. The
source-of-truth tables can be regenerated with `tools/gen_unicode_tables.rb`
from an explicitly supplied Unicode Character Database directory.
