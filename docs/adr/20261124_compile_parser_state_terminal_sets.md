# ADR: Use generated terminal sets for numeric LR state requests

- Status: Proposed
- Decision date: 2026-11-24
- Related: [20261122_parser_token_expectations.md / Decision](20261122_parser_token_expectations.md#decision)

## Context

`Flexr::Runtime#next_token` accepts `expect:` so a parser can select eligible
rules before scanning. An LR parser can request a token repeatedly from the
same state. Constructing the same expectation set at each request repeats
work the parser generator has already done.

Lrama 0.8.0 exposes its compiled action table through `Lrama::Context`. A
default reduction can apply to terminals without explicit actions. A
`%nonassoc` error in the same table can exclude one of those terminals.

## Decision

Read the grammar during lexer generation. Derive each LR state's terminal
set from the selected parser actions, including default reductions and
explicit error actions. Share identical sets. Carry the sets and rule masks
in generated lexer artifacts, and accept a numeric LR state through
`next_token(parser_state:)`. Apply the eligibility rules of `expect:`.

## Alternatives considered

The parser can construct an `expect:` array before each request. That keeps
the lexer independent of state numbering, but repeats the terminal lookup
and rule filtering on every scan. Letting the lexer inspect the live parser
would expose parser internals and require a parser dependency at runtime.

## Consequences

Generate the lexer and parser from the same grammar and parser configuration.
Their state numbers form a contract. The precomputed set describes actions
available at the top LR state. The parser can still reject a token after a
reduction exposes more of its stack. Lrama is a build dependency for this
option. Generated lexers can run in a process that loads Flexr alone.
