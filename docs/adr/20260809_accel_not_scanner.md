# ADR: Keep DFA rule selection authoritative during acceleration

- Status: Accepted
- Decision date: 2026-08-09
- Related: [Original decision](https://github.com/ydah/flexr/commit/5a4b46ae670376c4373e4b92e8cc80d4079ee691), [20260809_leftmost_longest.md / Decision](20260809_leftmost_longest.md#decision)

## Context

The DFA for a run of characters can stay in one state for many bytes.
`Flexr::Automaton::Accel.extract` finds such self-loops, and the interpreter
can skip a run of their bytes before considering acceptances again. Users
expect `accel` to affect speed while preserving their tokens and spans.

## Decision

Allow accelerators to skip transitions only when the DFA would make the
same selection. Preserve the accepted rule, byte span, and scan limits.
Keep an unaccelerated scan available through `accel :none`.

## Alternatives considered

Matching `/a|ab/` directly against `ab` can select `a` where a longest-match
DFA selects `ab`. Using that result as the winner would let an acceleration
setting change the language matched by a specification.

## Consequences

Applications can change the acceleration setting without changing their
token streams. An optimization is eligible only where it can preserve the
DFA's decisions, and accelerator changes can be checked against an ordinary
scan.
