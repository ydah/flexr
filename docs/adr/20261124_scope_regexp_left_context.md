# ADR: Keep regexp left context within the active input source

- Status: Proposed
- Decision date: 2026-11-24
- Related: [20261122_input_stack.md](20261122_input_stack.md#decision), [20261123_zero_width_regexp_lookahead.md](20261123_zero_width_regexp_lookahead.md#decision)

## Context

The lexer can suspend one source with `push_input` while it reads another
source. `Runtime::InputStack#push_input` gives the new source its own byte
offset and line coordinates. The lexer restores the parent source when the
child reaches EOF. A streaming lexer can also discard bytes behind its
cursor. As soon as a regexp can inspect text to its left, the scope of that
history affects which rules and captures can match at a source boundary.

## Decision

Evaluate left-context assertions at their position in the active input
source. They may inspect input before the token begins, including bytes
the lexer has consumed from that source. They never inspect another source
on the input stack. Starting a child source starts fresh context, and
resuming the parent restores the context it had when it was suspended.

`\A` matches byte offset zero of that source. `^` also matches after a line
feed when the source has another byte. Assertions leave the match length
and the lexer cursor unchanged.

## Out of scope

Which lookbehind expressions the compiler accepts, and how it represents
their history, remain separate from this source boundary decision. See
[20261123_zero_width_regexp_lookahead.md](20261123_zero_width_regexp_lookahead.md#decision)
for right-context selection.

## Alternatives considered

Read across source boundaries in token order. An included file could then
match differently depending on the parent's last bytes, and a parent's
next token could depend on the child it just finished. That would mix the
byte histories of sources with independent positions and lifetimes.

Restrict assertions to the current token candidate. This would avoid
maintaining any earlier context, but a lookbehind at the start of a rule
could never test text consumed by an earlier token.

## Consequences

The same source has the same left-context boundary whether scanned alone or
included. A scanner must preserve the information needed for assertions
when it discards input or suspends a source. A recognizer taking a byte
offset gets its left context from the string the caller supplies.
