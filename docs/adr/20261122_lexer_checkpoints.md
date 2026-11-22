# ADR: Restore a lexer with an opaque bookmark and seek by byte offset

- Status: Accepted
- Decision date: 2026-11-22
- Related: [#80](https://github.com/ydah/flexr/pull/80)

## Context

Parser and incremental-processing clients can resume a Flexr lexer at a saved position.
The byte position alone does not identify how the lexer will resume because lexical state, accumulated text, and EOF bookkeeping can differ at the same offset.
Streaming clients may also have discarded earlier input.

## Decision

Offer `checkpoint`, `restore`, and `seek` in runtime, generated, and standalone lexers.
Make a checkpoint an immutable, opaque bookmark for the lexer instance and active input.
Restore the cursor, lexical stack, and token and EOF bookkeeping while keeping scanning work cumulative.

Make `seek` a byte-oriented move to a retained, valid boundary with known coordinates.
Keep the lexical state and stack and start fresh token and EOF bookkeeping without running actions.
Bookmarks preserve cursor state without retaining extra input.

## Out of scope

Callers own application state and the side effects of actions.
Buffer retention, UTF-8 boundaries, and restrictions for layout and input-stack lexers are covered by the [runtime reference](../reference/runtime.md#checkpoint-and-seek).

## Alternatives considered

Restoring only a byte offset would lose state transitions and pending tokens.
Pinning input for the life of a bookmark would retain bytes beyond the client's streaming buffer policy.
An instance-bound bookmark captures the scanner state while leaving input retention under caller control.

## Consequences

Clients can resume rule selection from a bookmark or change the byte cursor while preserving lexical state.
Replayed reads can rerun actions, and a bookmark becomes unusable after the needed input bytes are discarded.
