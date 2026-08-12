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

Experimental compatibility behavior. It requires `option :experimental` and
can return a shorter match merely because its rule appears earlier. Runtime and
generated artifacts preserve that same behavior. Potential differences from
the stable longest-match backends are reported with `FLEXR-W010`.

## Acceleration and packing

Region acceleration and packed tables are representations, not semantic
backends. `accel` can be disabled for debugging or equivalence tests. Table
compression and packed Base64 output trade source size against loading cost;
packed transitions are queried without creating a second dense table, and a
dense row is materialized lazily only for inspection. These choices do not
change token streams.
