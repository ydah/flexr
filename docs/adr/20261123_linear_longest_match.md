# ADR: Run ordinary longest-match scanning in linear time

- Status: Proposed
- Decision date: 2026-11-23
- Related: [DFA backup analysis](https://github.com/ydah/flexr/pull/104), [20261123_snapshot_string_inputs.md](20261123_snapshot_string_inputs.md#decision)

## Context

In flexr 2.2.0, `Flexr::Runtime::Interpreter#scan` searches from the current
token start until the DFA has no transition or the input ends. For rules
`/a/` and `/a*b/` on a string of `a` bytes, the second rule remains possible
up to the end of the input. After emitting each single-byte token, the
scanner repeats the search over the remaining suffix. This requires a
quadratic number of byte reads for the same rules.

Thomas Reps shows that a scanner can reuse failures keyed by DFA state and
input position. Flexr's DFA backup analysis identifies the nonaccepting
cycles where retrying a failed continuation can repeat work.

[Maximal-Munch Tokenization in Linear Time](https://research.cs.wisc.edu/wpis/abstracts/toplas98b.abs.html)

## Decision

Guarantee linear DFA traversal in input length for a fixed specification
during ordinary forward longest-match scanning on stable bytes. Reuse a
failed continuation only when it reaches a dead end or confirmed EOF
without reaching a DFA acceptance for any rule. A later scan may use the
same fact with a different token expectation or line position. Use the
same rule selection and match boundaries in runtime, generated, and
standalone lexers.

Allocate failure records for nonaccepting cycles reachable after an
acceptance, or before the first acceptance when unmatched input can be
recovered. Bound the cost of intervening acyclic paths by the size of the
DFA. Scope records to the input and DFA, and discard records behind the
active byte window. Preserve the existing resource limits when reusing
a failure.

## Out of scope

The guarantee covers the body DFA traversal. Rule actions can rewind the
lexer with `less` or inspect additional input. Eligibility checks can
reject a raw DFA acceptance, and trailing context can scan independently
from each candidate. Those operations retain their own costs. First-match
selection continues to follow [20261122_stable_explicit_firstmatch.md](20261122_stable_explicit_firstmatch.md#decision).

## Alternatives considered

Stopping at a fixed lookahead length would reject inputs that the existing
longest-match rules accept. Memoizing every nonaccepting state would also
cover finite, bounded backup paths at the cost of lookups and memory on
specifications that already scan in linear time.

## Consequences

Later tokens can stop searching a suffix once the DFA has already proved
it cannot accept there. A long unresolved candidate can still require
memory proportional to the scanned portion of the input. Mutable backing
strings exposed to callers and scans that count every step use the existing
traversal to preserve edits, step limits, and cancellation callbacks.
