# ADR: Rank shortest matches by rule body length in opted-in lexical states

- Status: Proposed
- Decision date: 2026-11-24
- Related: [20260809_leftmost_longest.md / Decision](20260809_leftmost_longest.md#decision), [20261122_explicit_rule_priority.md / Decision](20261122_explicit_rule_priority.md#decision)

## Context

`Flexr::Runtime::Interpreter#scan` ranks the body and `followed_by:` together
for longest matching. It consumes only the winning body. The
[shortest-match experiment](../perf-log.md#shortest-match) shows the distinction
on `abcd`. A rule with body `"a"` and trailer `"bcd"` consumes one byte and
matches four in all. A rule with body `"ab"` consumes two bytes. A scanner
state used to find a delimiter can need the first eligible body boundary
while other states in the same grammar still need longest matching.

## Decision

Let users declare `match: :shortest` on a lexical state in a DFA-backed lexer.
At the earliest valid UTF-8 or binary body boundary, select an eligible rule
by priority and then declaration order. Apply anchors, `expect:`, and
`followed_by:` before selecting the rule. Leave the trailing bytes available
for the next token. Use the state policy for recognition, trace, and
diagnostic witnesses.

## Alternatives considered

Ranking by the combined body and trailer length would select `"ab"` in the
example. That would delay selection beyond the first eligible body boundary.
A separate backend would apply its selection policy to the whole lexer, even
when a single state needs shortest matching.

## Consequences

Each state can choose the boundary that fits its grammar. The default state
policy is longest matching. A rule can require lookahead beyond the body
before its earliest eligible boundary can be confirmed. The `firstmatch`
backend uses Ruby regexp order and rejects the shortest state option.
