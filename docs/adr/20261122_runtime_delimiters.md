# ADR: Let a rule action consume a delimiter chosen from the input

- Status: Accepted
- Decision date: 2026-11-22
- Related: [#86](https://github.com/ydah/flexr/pull/86)

## Context

A Flexr 2.2 lexer can recognize a tagged heredoc opener with a regular
expression. The opener's capture supplies the closing tag only after the rule
matches. Scanning the body on an IO input must account for a delimiter split
across reads and the token's position in the original source.

## Decision

Let a matched rule call `scan_until` or `scan_until_line` to search the active
input from the current cursor under the lexer resource limits. On success
consume the first matching delimiter, extend the current match, and return the
body before the delimiter. A line delimiter must occupy an entire LF, CRLF,
or EOF-terminated line.

At EOF with no match, return `nil` and keep the cursor and current match at
their pre-call positions. The rule action decides how to report a required
delimiter that was missing.

## Out of scope

See [the contextual lexer implementation notes](../implementations/20261122_contextual_lexer_runtime.md#dynamic-delimiters)
for literal search on the streaming buffer and standalone helper selection.

## Alternatives considered

A fixed set of closing-tag rules cannot cover tags chosen by the source.
Searching in application code would require callers to manage the same
stream, token coordinates, and work limits alongside the lexer.

## Consequences

One rule can emit a token spanning the opener, body, and terminator in runtime,
generated, and standalone lexers. A failed search can still read and retain
bytes from IO. Callers must handle the `nil` result where a delimiter is
required. See [dynamic delimiters in rule actions](../reference/actions.md#dynamic-delimiters).
