# ADR 0031: Preserve trivia in named token channels

## Context

Parser adapters consume semantic tokens. Formatters and editor tools also
need comments, whitespace, and locations, which discard rules remove from
the stream.

## Decision

Route emitted tokens by the selected rule's channel after matching and its
action. Keep the same DFA, precedence, and state transitions. The default
consumers and Racc expose the default channel. `tokens(channels: :all)`
includes named trivia channels in source order. `channel: :skip` and
`skip: true` discard the match in both views.

Structured tokens carry trivia as immutable metadata outside their existing
data members. Array and yield tokens keep their two-element shape. Hidden
tokens retain the byte ranges captured during their actions, including in
streaming mode. Ordinary lexers use the existing scanner and emission path.

Generated artifacts store channel metadata only when named channels are used.
Ordinary artifacts continue to use the same payload. Standalone generation
embeds the trivia runtime for lexers that use named channels.
