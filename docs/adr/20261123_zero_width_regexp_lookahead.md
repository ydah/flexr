# ADR: Keep regexp lookahead zero-width during rule selection

- Status: Proposed
- Decision date: 2026-11-23
- Related: [20260809_leftmost_longest.md](20260809_leftmost_longest.md#decision), [20261122_stable_explicit_firstmatch.md](20261122_stable_explicit_firstmatch.md#decision), [20261122_named_captures_of_selected_rule.md](20261122_named_captures_of_selected_rule.md#decision)

## Context

Flexr 2.2.0 rejects positive and negative regexp lookahead. Its suggested
rewrite for a trailing positive assertion uses `followed_by:`.
That option counts the combined length of the rule body and its trailing
match when choosing a longest match. For example,
`rule(/a/, followed_by: /bc/)` can win against `rule(/ab/)` on `abc`
even though it consumes just `a`. Ruby's regexp lookahead checks for a
match at its position without advancing that position. [Ruby regexp lookahead syntax](https://docs.ruby-lang.org/en/4.0/Regexp.html#class-Regexp-label-Lookahead+Assertions)

## Decision

Evaluate positive and negative regexp lookahead at its position in the rule
body. The assertion may read ahead in the active input source, including
past the end of the selected token. Count only the consuming portion of the
regexp when ranking longest matches. Preserve the combined-length ranking
of explicit `followed_by:` rules. Preserve Ruby's ordered choice of
alternatives and named captures for the selected match.

## Out of scope

Left-context assertions and the scope of their input history will be
decided in a separate ADR.

## Alternatives considered

Translate a trailing positive assertion into `followed_by:`. This would
reuse trailing-context matching but could change the winning rule and
advance the lexer by a different number of bytes. It would also leave
negative assertions and internal assertions without an equivalent.

Evaluate assertions against only the bytes of the selected token. That
would make a match depend on where a chunk or token ends, even though the
next bytes are still present in the active source.

## Consequences

Ruby regexp assertions can express context without consuming the
context or increasing the rule's match length. A streaming match can
need more input before it selects a rule or resolves a named capture.
The additional context is subject to the lookahead and buffer limits.
