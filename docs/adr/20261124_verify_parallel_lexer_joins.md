# ADR: Verify speculative lexer joins against the uninterrupted input

- Status: Proposed
- Decision date: 2026-11-24
- Related: [20261124_reuse_lexing_across_input_edits.md / Decision](20261124_reuse_lexing_across_input_edits.md#decision), [20261123_linear_longest_match.md / Decision](20261123_linear_longest_match.md#decision)

## Context

A Flexr token can cross a proposed split. For example, a rule with `/a+/` can cross any split in a run of `a` bytes even though its DFA backup bound is zero. A worker that treats its slice as a separate source can also satisfy an EOF assertion before the real end of input. Rule actions can run Ruby code, so running a speculative action can affect application state even if the coordinator discards its token.

## Decision

Parallel tokenization shares one immutable input. A proposed cut is a position in that source. Adopt a worker's output after a boundary matches the state and context of the confirmed scan, using the same comparison as incremental lexing. If the boundaries differ, continue from the last confirmed boundary until a later candidate matches. Keep ordinary serial execution for specifications with opaque actions.

## Out of scope

Parallel execution of declared-pure Ruby actions requires a separate action contract. This decision applies to one in-memory input and the default-channel token stream.

## Alternatives considered

Independent slices create artificial EOF and lose the prefix needed by left-context assertions. Verifying every token with a second complete scan preserves behavior but repeats the work that parallel execution is meant to distribute. Assuming a finite backup bound limits token length permits invalid joins in accepting DFA loops.

## Consequences

Parallel and serial scans have the same token and location contract. Useful cuts avoid most coordinator rescanning. Sparse delimiters, long tokens, or differing layout state can increase repair work. The coordinator reproduces a lexical failure from a verified state before reporting it to the caller.
