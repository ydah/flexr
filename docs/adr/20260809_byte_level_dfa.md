# ADR: Compile lexer transitions over bytes

- Status: Accepted
- Decision date: 2026-08-09
- Related: [Original decision](https://github.com/ydah/flexr/commit/5a4b46ae670376c4373e4b92e8cc80d4079ee691)

## Context

Flexr scans UTF-8 text and arbitrary binary input through the same generated
and runtime interfaces. Lexer positions and token spans use byte offsets.
`Flexr::Runtime::Interpreter#scan` reads bytes from the buffer. A byte that
cannot start a UTF-8 match reaches `Flexr::Runtime#handle_unmatched_byte` and
advances recovery by one byte.

## Decision

Use bytes as the DFA transition alphabet. Compile Unicode scalar ranges into
valid UTF-8 byte sequences so text patterns honor codepoint boundaries. Use
the full byte alphabet for binary specifications.

## Alternatives considered

A character-oriented DFA would need to decode characters during scanning and
handle invalid UTF-8 and binary input separately. Compiling byte sequences
lets both encodings use the same transition model and enables binary region
acceleration.

## Consequences

Runtime and generated lexers share the byte-oriented machine model. Changing
the transition alphabet would require changes to both scanners and to their
serialized transition tables. The compiler must express Unicode boundaries
using byte transitions. The [encoding explanation](../explanation/unicode-and-encoding.md)
describes how the two supported encodings behave.
