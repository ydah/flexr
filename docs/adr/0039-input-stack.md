# ADR 0039: Suspend input across include boundaries

## Context

A lexer action may recognize an include directive and need to insert another
source into the token stream. Both sources need their own coordinates,
EOF actions, and lexical states. An action can still use the directive's
matched text and location after it calls `push_input`.

## Decision

Validate a new buffer when `push_input` queues it. Activate it between token
matches and save the previous buffer and cursor. Start the new file at byte
zero with the initial lexical state. Run its EOF actions before restoring
the suspended buffer and cursor. Keep work accounting, cancellation, and the
configured recovery policy on the lexer instance.

Associate each checkpoint with the active input identity. Its restoration
operates on that input's cursor, while pending source pushes and application
state follow the actions that scheduled them. Keep IO open under caller
ownership so a child can consume it incrementally.

Embed the separate input stack helper only when a standalone grammar calls
`push_input` or explicitly selects `option :input_stack`. Generated rules
use the same buffer transition as interpreted rules.
