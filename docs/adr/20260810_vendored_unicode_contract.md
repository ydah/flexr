# ADR: Use vendored Unicode data as the compatibility contract

- Status: Accepted
- Decision date: 2026-08-10
- Related: [Original decision](https://github.com/ydah/flexr/commit/52b9d99d475af73c3a1f64d491d20c795504a445), [20260809_byte_level_dfa.md / Decision](20260809_byte_level_dfa.md#decision)

## Context

Host Ruby updates can change the Unicode tables used by `Regexp`. A lexer
with the same specification could then accept different characters after a
Ruby upgrade. Flexr 2.2.0 declares Unicode 15.1.0 in
`Flexr::Unicode::VERSION`, and `Flexr::Unicode::Property.ranges` reads the
vendored property data.

## Decision

Use the vendored Unicode Character Database snapshot for `\p{...}`, POSIX
character classes backed by Unicode properties, shorthands under
`option :unicode`, and case folding. Treat a snapshot update as a
minor-version compatibility change and regenerate golden output.

## Alternatives considered

Using the host's Unicode tables would avoid storing a snapshot. It would let
a Ruby upgrade change the accepted language of a flexr specification without
a flexr version change.

## Consequences

The same flexr snapshot provides character ranges to runtime and generated
lexers. flexr maintainers need to record and verify data updates. The
[verification record](../implementations/20260810_vendored_unicode_verification.md)
describes regeneration and checks.
