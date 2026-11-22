# ADR: Apply parser token expectations before selecting a rule

- Status: Accepted
- Decision date: 2026-11-22
- Related: [#81](https://github.com/ydah/flexr/pull/81)

## Context

The [Ruby slash example](../how-to/parser-driven-lexing.md#ruby-division-and-regexp-literals) recognizes both division and regexp literals.
On `/a/`, unrestricted longest matching selects the whole literal even when the parser only allows division after an operand.
The parser's current terminal set is available before the lexer reads a token.

## Decision

Accept an optional `expect:` array of token symbols in `next_token` and `racc_next_token`.
Filter candidates using `emit:`, rule-level `emits:`, and the keyword type for the exact candidate lexeme.
Keep skip rules, trivia rules, and actions with unknown output types eligible so scanning can advance and apply state changes.
An `emits:` annotation describes eligibility, and the action chooses the emitted type.

Apply the backend's normal ranking to the eligible candidates, including trailing context and tie-breakers for longest match and native rule and regexp order for `firstmatch`.
Keep normal EOF and error recovery behavior.

## Out of scope

The parser controls whether to supply expectations and how to handle a token it does not accept.
The [parser-facing scan paths record](../implementations/20261122_parser_facing_scan_paths.md#expected-tokens) describes generated and standalone support.

## Alternatives considered

Checking the token type after unrestricted scanning comes too late to select a shorter candidate that was valid for the parser state.
Requiring output annotations on every rule would make existing actions and trivia unusable until the specification was rewritten.

## Consequences

A parser can guide rule selection for one read without changing the specification or global rule order.
An unannotated or multi-type action can still emit a type that the parser must handle.
Without expectations, token selection retains the original behavior.
