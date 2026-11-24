# ADR: Reuse tokens only when an edit leaves their inputs and lexer state equivalent

- Status: Proposed
- Decision date: 2026-11-24
- Related: [20261122_lexer_checkpoints.md / Decision](20261122_lexer_checkpoints.md#decision), [20261124_scope_regexp_left_context.md / Decision](20261124_scope_regexp_left_context.md#decision)

## Context

Flexr can inspect bytes beyond the token it emits. For example, rules for `a` and `a+z` emit separate `a` tokens on `aaa`. Appending `z` turns the whole input into one token. A failed extension can therefore make a token depend on bytes beyond its location or on the old end of input. At the other end of an edit, two scans can reach the same byte with different state stacks or lookbehind histories.

Ordinary lexer checkpoints belong to one lexer and one input. Rule blocks can also use state outside a checkpoint, such as Ruby objects they close over or coordinates they put in token values.

## Decision

An incremental lexer represents an immutable revision of one String. Applying an edit produces another revision. Restart at the last token boundary whose preceding scan has not examined a changed byte or the replaced end of input.

Reuse the unchanged suffix only when the new scan reaches the corresponding old byte with equivalent lexical state, DFA start, and left context. Translate the reused token locations for the edit. Treat opaque actions as requiring a full scan unless the caller declares that their results depend only on the current match and recorded lexer state.

## Out of scope

Keep public lexer checkpoints bound to their original lexer and input. Parallel scanning will use the same boundary comparison and will decide separately which actions are eligible for speculation.

## Alternatives considered

Restarting at the token that overlaps the edit misses earlier failed matches and assertions. Joining at the first repeated token can reuse an incorrect suffix after a change to lexical state or lookbehind. Scanning the entire replacement is exact, but repeats token selection after a provable join.

## Consequences

Local edits can retain tokens on both sides without repeating their scans. Edits to bytes inspected by many tokens can move the restart far from the edit. A join also has to update locations for reused structured tokens. The caller must use the full-scan behavior for actions that have effects, use unrecorded state, or put source coordinates in token values.
