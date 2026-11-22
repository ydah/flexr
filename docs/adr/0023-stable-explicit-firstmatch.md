# ADR 0023: Stabilize explicit firstmatch selection

## Context

First-match selection helps port rule sets that depend on source order.
Runtime and generated lexers already supported this behavior behind an
experimental flag. For example, when `/a/` precedes `/ab/`, a first-match
lexer can consume just `a` from `ab`. A longest-match lexer consumes `ab`.

## Decision

Selecting `backend :firstmatch` is sufficient to opt in to stable first-match
behavior. Runtime and generated lexers select the first matching rule in
source order and honor Ruby regexp alternative order within a rule. Keep
accepting `option :experimental` for older specifications. Report potential
differences from longest match through `FLEXR-W010`.

`table` remains the default. It, `direct`, and `auto` follow the
leftmost-longest contract described in [ADR 0003](0003-leftmost-longest.md).
Choose `firstmatch` when the source rule ordering is part of the lexer
contract.
