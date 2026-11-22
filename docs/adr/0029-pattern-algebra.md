# ADR 0029: Treat patterns as composable regular languages

## Context

Lexers often reuse the same identifier or delimiter in several rules.
Users also need to exclude keywords or restrict the length of an existing
pattern. These operations can be expressed using the same DFA as rule matching.

## Decision

`pattern` and `upto` create immutable values that copy literal inputs and
can be shared across Ractors. The static reader resolves constant references
in source order and retains their names for inspection. The runtime accepts
the same value expressions in normal Ruby class bodies.

Compile union and concatenation through the NFA. Compile intersection and
difference with bounded DFA products. Complement uses the subject alphabet
as the left operand of difference. Embed resulting DFAs as fragments so the
enclosing lexer continues to use longest-match and source order.

`upto` uses the language of strings ending at the delimiter. Remove the
outgoing transitions of accepting states before embedding the DFA. This
makes the earliest completed delimiter definitive even when a later
occurrence overlaps it.

Continue to use the DFA for pattern-based rule bodies and lookahead.
Require a longest-match backend for these rule bodies because explicit
`firstmatch` keeps Ruby regexp alternative order. Generated and standalone
lexers serialize the compiled tables and retain pattern descriptions for
tracing and diagnostics.
