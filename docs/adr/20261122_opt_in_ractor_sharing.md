# ADR: Prepare generated lexers for Ractor sharing on request

- Status: Accepted
- Decision date: 2026-11-22
- Related: [#65](https://github.com/ydah/flexr/pull/65), [#40](https://github.com/ydah/flexr/pull/40)

## Context

Generated classes store compiled transition data that separate Ractors can
reuse. Packed tables can materialize rows lazily, and closures, EOF blocks,
and firstmatch Unicode reference caches can retain state that cannot be
shared. `Flexr::Generated.shareable!` checks these constraints before
preparing compiled data.

## Decision

Require the application to call `Flexr::Generated.shareable!(Lexer)` in the
main Ractor before it creates workers. Share compiled data and configuration
and let each worker create its own lexer and input. Raise `ArgumentError`
for runtime specifications, captured action closures, EOF blocks, and
`firstmatch` patterns that require the Unicode reference matcher.

## Alternatives considered

Preparing every generated lexer at load time would eagerly allocate dense
transition rows for applications that use a single Ractor. Using the
unprepared generated class would defer failures with non-shareable actions
until an application tries to use the lexer in another worker.

## Consequences

Users control the preparation time and memory cost. User-defined methods
must obey Ruby's Ractor rules. For patterns that use the incompatible
firstmatch cache, `table`, `direct`, and `auto` remain available. The
[generated artifacts reference](../reference/generated-artifacts.md#ractor-sharing)
shows how a worker loads and uses prepared data. The
[runtime implementation record](../implementations/20261122_v2_runtime_implementation.md)
describes table preparation.
