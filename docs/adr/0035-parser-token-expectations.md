# ADR 0035: Filter rule selection by parser token expectations

## Context

The same text can have different meanings depending on the grammar position.
A parser may know which terminal types it can accept before it requests the
next token. Flexr already tracks every accepting rule in each DFA state.

## Decision

Accept an optional `expect:` array in `next_token` and `racc_next_token`. Use
`emit:` and rule-level `emits:` to determine eligibility. Consult the keyword
table using the exact candidate lexeme. Keep skip rules, trivia, and rules
without known output types eligible so they can advance the input or update
state. A multi-type annotation supplies eligibility information for a rule.
The action still decides which type to emit.

Use the interpreter's DFA acceptance lists for filtered longest-match
scans. Anchors, trailing context, and tie breakers retain their semantics.
The scan still observes the configured resource limits. Filter candidates in
the native scanner for `firstmatch` to preserve regexp and rule order.

Keep the existing generated scan path for unrestricted calls. Same-ABI
generated lexers already embed enough DFA data for the updated runtime to
filter `emit:` rules. New artifacts carry rule-level annotations as optional
metadata. An existing standalone artifact needs regeneration to embed the
updated runtime.
