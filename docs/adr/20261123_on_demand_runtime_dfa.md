# ADR: Construct uncached runtime DFA transitions as input reaches them

- Status: Proposed
- Decision date: 2026-11-23
- Related: [20261123_derivative_dfa_construction.md](20261123_derivative_dfa_construction.md#decision), [20260809_leftmost_longest.md](20260809_leftmost_longest.md#decision)

## Context

In flexr 2.2.0, creating a runtime lexer calls `Lexer.compile!`, which
builds every reachable DFA state before the lexer reads its input.
The derivative compiler can compute a single successor from a state and
a byte class. This makes it possible to scan a short prefix without
constructing the states used by other inputs.

`Lexer.compile!` and `Lexer.dfa` expose the complete graph and its
diagnostics. The disk cache stores complete tables. Explicit acceleration
and automatic backend selection also use properties of the complete graph.

## Decision

Validate the specification before creating a lexer. For uncached runtime
`:table` and `:direct` scanners, construct and reuse a DFA transition when
input first takes that transition. Keep longest-match and rule priority
selection identical to that of the complete DFA.

Build the complete graph for explicit compilation, inspection, and parser
recognizers. Keep complete construction for static generation, the disk
cache, explicit acceleration, automatic backend selection, and explicit
state limits.

## Alternatives considered

Always build the complete graph at initialization. This keeps subsequent
scanning work predictable, but every short-lived process pays to construct
states its input may never reach.

Serialize the partial graph to the disk cache. Its contents would depend on
which inputs ran in each process. Complete tables allow later processes to
reuse a deterministic artifact and inspect the whole DFA.

## Consequences

An uncached scanner can start before the entire graph exists. Its first
visit to a transition pays the cost of constructing that transition.
Full compile diagnostics remain available on request. The default state
limit can be reached while scanning as the runtime discovers states.
