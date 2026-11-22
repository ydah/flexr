# Backends

## `table`

The stable default. It stores DFA transitions by byte class and can apply row
compression. It is the clearest reference for semantics and is the comparison
target for `firstmatch`.

## `direct`

The stable dense-dispatch backend. It emits one flattened transition structure
and avoids retaining a second packed or row table. It can reduce lookup
overhead at the cost of artifact size and preserves the table backend's
leftmost-longest behavior.

## `auto`

The stable selection policy. At compile time it compares estimated dense bytes,
packed bytes, and lookup cost for each lexical-state machine. The effective
backend is recorded in generated headers.

## `firstmatch`

Stable compatibility behavior selected explicitly with `backend :firstmatch`.
Runtime and generated lexers select the first matching rule in source order,
even when a later rule could consume more text. `FLEXR-W010` reports potential
differences from longest-match backends. See
the [first-match compatibility record](../adr/20261122_stable_explicit_firstmatch.md#decision) for the decision.

## Acceleration and packing

Region acceleration and packed tables are representations, not semantic
backends. `accel` can be disabled for debugging or equivalence tests. Table
compression and packed Base64 output trade source size against loading cost;
packed transitions are queried without creating a second dense table, and a
dense row is materialized lazily only for inspection. These choices do not
change token streams.

Explicit `accel :strscan` also derives complete-token expressions from the DFA.
For each starting-byte branch, all accepting states must select the same rule.
The reachable graph may have self-loops but no other cycles, and every edge
must consume ASCII bytes. Outgoing byte sets are disjoint because they come
from deterministic transitions. A greedy self-loop cannot consume an exit
byte; greedy optional exits therefore find the longest accepted prefix without
adopting the original Ruby regexp's alternation priority. Unproven branches
fall back to DFA traversal.

Expression expansion is capped at 32 states per path and 4 KiB per expression.
Plans are shared by lexer instances through their compiled machine. Native
scans use `StringScanner#skip`, retaining byte lengths without materializing
matched text. The fast path is disabled for mutable or streaming input,
non-retained buffers, token/step/cancellation guards, anchors, trailing context,
and `firstmatch`. These restrictions preserve the DFA's boundary and resource
checks.
