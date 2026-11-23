# ADR: Evaluate end anchors against the active input source

- Status: Proposed
- Decision date: 2026-11-23
- Related: [20261123_zero_width_regexp_lookahead.md](20261123_zero_width_regexp_lookahead.md#decision), [20261122_input_stack.md](20261122_input_stack.md#decision)

## Context

Flexr 2.2.0 limits `$` to the outermost rule-pattern boundary and rejects
`\z` and `\Z`. The suggested rewrite to `$` only works for input without
line feeds. For example, Ruby 4.0.9 matches `/a$/` before the LF in
`a\nb`, while `/a\Z/` fails there. A streamed lexer may have loaded only
`a\n` when it first checks the assertion. Included sources also end before
the parent source resumes. [Ruby regexp anchors](https://docs.ruby-lang.org/en/4.0/Regexp.html#class-Regexp-label-Anchors)

## Decision

Evaluate `\z` at the end of the active source, and evaluate `\Z` there or
immediately before its final LF. Evaluate `$` at the end of the active
source or immediately before any LF. Permit all three assertions inside a
pattern. Each assertion consumes zero bytes and uses the same source
boundary when resolving named captures or first-match alternatives.
Malformed input bytes remain part of the source.

## Alternatives considered

Evaluate assertions against the loaded prefix or the selected token.
This would let a chunk boundary or a token boundary stand in for the source
end, changing results with the input delivery method.

Translate both source-end assertions to `$`. That would allow a line feed
followed by more input to satisfy `\Z` and let a final LF satisfy `\z`
before the LF is consumed.

## Consequences

A lexer can use one rule for line endings and another for source endings.
An end assertion can trigger a refill to establish whether the required
suffix is present. An included source can satisfy an end assertion before
its parent resumes.
