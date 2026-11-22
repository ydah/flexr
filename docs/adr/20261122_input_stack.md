# ADR: Suspend the parent input while a lexer scans an included source

- Status: Accepted
- Decision date: 2026-11-22
- Related: [#84](https://github.com/ydah/flexr/pull/84), [20261122_lexer_checkpoints.md / Decision](20261122_lexer_checkpoints.md#decision)

## Context

When a Flexr 2.2 rule finds an include directive, its action still needs the
text and location of the directive. The included source can start in a
different lexical state and has its own filename, coordinate origin, and EOF
actions. `Flexr::Runtime#push_input` queues the source so both requirements can
hold in a single token stream.

## Decision

Enter each queued source at a token boundary. The child starts in the initial
lexical state with its own filename and coordinates. Run its EOF behavior,
including final dedents when using indentation, before resuming the parent's
saved position, lexical state, and layout. Read simultaneous pushes in
last-in, first-out order.

A checkpoint can restore its position only while its source is active. Share
the lexer's work budget, cancellation, and recovery policy across sources.

## Out of scope

The data stored in suspended input frames and standalone helper selection are
described in [the contextual lexer implementation notes](../implementations/20261122_contextual_lexer_runtime.md#input-stack).

## Alternatives considered

Replacing the active input during the action would change the source of the
directive's token. Flattening included text into the parent would require a
separate mapping for locations and a way to synthesize each child's EOF and
initial lexical state.

## Consequences

Parsers can consume the included tokens in the same stream and report errors
against the file that produced them. Callers must keep included IO open until
consumption finishes. Restoring a checkpoint from an inactive
source raises an error. See the [input stack reference](../reference/runtime.md#input-stack).
