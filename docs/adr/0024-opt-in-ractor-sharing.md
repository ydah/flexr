# ADR 0024: Prepare generated lexers for Ractor sharing explicitly

## Context

Generated lexers can share compiled transition tables between Ractors while
each Ractor owns its lexer and input. Packed tables materialize rows lazily,
and some actions or matcher caches carry state that cannot be shared.

## Decision

Call `Flexr::Generated.shareable!(Lexer)` in the main Ractor before creating
workers. Preparation materializes dense transition rows and makes the
compiled data and configuration shareable. Each worker then constructs its
own lexer. The explicit call puts the memory cost and preparation timing
under the application's control.

Preparation raises `ArgumentError` for runtime specifications, captured
action closures, EOF blocks, and firstmatch patterns that need the Unicode
reference matcher. Its shared caches are unsafe to use across Ractors. Use
`table`, `direct`, or `auto` for those patterns. User-defined methods still
need to follow Ruby's Ractor rules.

See the [generated artifacts reference](../reference/generated-artifacts.md#ractor-sharing)
for a working example.
