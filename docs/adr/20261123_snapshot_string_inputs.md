# ADR: Take a frozen snapshot of each mutable String input by default

- Status: Proposed
- Decision date: 2026-11-23
- Related: [#105](https://github.com/ydah/flexr/pull/105), [20260809_accel_not_scanner.md / Decision](20260809_accel_not_scanner.md#decision)

## Context

`Runtime::Buffer` keeps the String passed to `Lexer.new`. Calls such as
`File.read` supply a mutable String, so the scanner cannot reuse validation
of that String across reads. The workload matrix measures slower scanner
paths on mutable input. Remembering failed DFA positions also requires the
bytes at those positions to stay stable.

## Decision

Take one frozen snapshot when the lexer receives a mutable String through
`Lexer.new` or `push_input`. Reuse Strings that are already frozen. Apply
`freeze_input: false` to explicitly borrow a caller-owned mutable String.

## Out of scope

An IO input continues to read incremental chunks. The scan strategy and
its matching contract are covered by [20260809_accel_not_scanner.md / Decision](20260809_accel_not_scanner.md#decision).

## Alternatives considered

Borrowing every mutable String lets caller edits change a scan after it
starts. It also requires repeated validation and prevents reuse of work
keyed to byte positions. Freezing the caller's String in place would make
subsequent mutations through existing references raise `FrozenError`.

## Consequences

The lexer has stable bytes for its fast paths without changing the caller's
String. A mutable input incurs one snapshot when it enters a lexer. Code
that deliberately changes the String after constructing the lexer can opt
out at construction.
