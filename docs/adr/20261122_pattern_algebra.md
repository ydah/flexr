# ADR: Expose composable regular languages as immutable pattern values

- Status: Accepted
- Decision date: 2026-11-22
- Related: [#71](https://github.com/ydah/flexr/pull/71)

## Context

A Flexr specification may need one identifier rule for an unrestricted name and a second rule that excludes selected spellings or bounds the same identifier's length.
Copying or rewriting the regexp for each rule makes the constraints hard to keep in sync.
The static generator also needs to resolve the same combinations as runtime evaluation.

## Decision

Expose `pattern` and `upto` as immutable, Ractor-shareable `Flexr::Pattern` values that authors can name and reuse.
Provide `|`, `+`, `&`, `-`, and `!` for union, concatenation, intersection, difference, and complement over the subject alphabet.
`upto` includes the first completed terminator, even when a later occurrence overlaps it.

Use these values in longest-match rule bodies and in trailing context on all backends.
Resolve statically available pattern names in source order and preserve their names in inspection output.

## Out of scope

The [pattern algebra implementation record](../implementations/20261122_pattern_algebra.md) describes automaton layouts and size checks.

## Alternatives considered

Named methods such as `minus` and `and` could express the same operations.
The operators let related operations form one expression and follow the familiar Ruby operators for concatenation and set operations.
Expanding each result into a Ruby regexp would also restrict combinations to those the native regexp selector can express and rank in the same way.

## Consequences

Runtime, generated, and standalone lexers keep the same language and the existing rule ranking.
Authors can change a named operand in one place and inspect where it is used.
Products can grow the DFA, and static generation requires operands it can resolve at build time.
