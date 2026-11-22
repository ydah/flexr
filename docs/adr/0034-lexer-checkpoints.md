# ADR 0034: Checkpoint a lexer's position and state

## Context

Parser and incremental-processing clients need to resume a lexer at a saved
position. The runtime tracks its lexical stack, line and column, accumulated
text, and EOF actions alongside the byte offset.

## Decision

Expose `checkpoint`, `restore`, and `seek` on each lexer in runtime, generated,
and standalone mode. A checkpoint is an opaque immutable value tied to the
lexer instance. Restoring it reuses that instance's buffer and restores the
cursor, lexical stack, token bookkeeping, and EOF state. The scanning step
counter remains cumulative. Callers control application state changed by
actions.

Seek is a byte-oriented move that validates a buffered offset and derives
coordinates without running actions. It retains the lexical state and stack
while starting fresh token and EOF bookkeeping. A checkpoint holds cursor
state without retaining additional input. The streaming buffer's existing
retention policy determines which positions remain available.

See the [runtime reference](../reference/runtime.md#checkpoint-and-seek)
for IO and UTF-8 boundaries.
