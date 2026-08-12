# Backends

## `table`

The stable default. It stores DFA transitions by byte class and can apply row
compression. It is the clearest reference for semantics and is the comparison
target for `firstmatch`.

## `direct`

The stable dense-dispatch backend. It emits a flattened dispatch structure for
large machines and can reduce lookup overhead at the cost of artifact size.
It preserves the table backend's longest-match behavior.

## `auto`

The stable selection policy. At compile time it chooses direct dispatch when the
largest state-by-byte-class table exceeds the configured threshold, otherwise
it uses table dispatch. The effective backend is recorded in generated headers.

## `firstmatch`

Experimental compatibility behavior. It requires `option :experimental` and
can return a shorter match merely because its rule appears earlier. Runtime and
generated artifacts preserve that same behavior. Potential differences from
the stable longest-match backends are reported with `FLEXR-W010`.

## Acceleration and packing

Region acceleration and packed tables are representations, not semantic
backends. `accel` can be disabled for debugging or equivalence tests. Table
compression and packed Base64 output trade source size against loading cost;
they do not change token streams.
