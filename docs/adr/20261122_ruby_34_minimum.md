# ADR: Require Ruby 3.4 or later for flexr 2

- Status: Accepted
- Decision date: 2026-11-22
- Related: [#65](https://github.com/ydah/flexr/pull/65), [#40](https://github.com/ydah/flexr/pull/40), [20260809_what_pure_ruby_means.md / Decision](20260809_what_pure_ruby_means.md#decision)

## Context

Flexr 1.1.0 declares Ruby 3.1 for the runtime and Ruby 3.3 for generation in
`flexr.gemspec`. Flexr 2.0 changes both structured token records and the
generated artifact ABI, giving users one point to migrate Ruby and regenerate
their lexers.

## Decision

Require Ruby 3.4 or later for flexr 2 runtime mode, generation, and standalone
artifacts. Apply the same language-level requirement to alternate Ruby
implementations. Keep the generator's distinct Prism dependency described in
[20260809_what_pure_ruby_means.md / Decision](20260809_what_pure_ruby_means.md#decision).

## Alternatives considered

Keeping different minima would preserve the installability of the runtime
on older Ruby versions. Maintainers would retain separate language targets
for generation and deployment across the new artifact ABI.

## Consequences

Users on older Ruby versions must upgrade Ruby before installing flexr 2.
Users with v1 generated files must also regenerate them. See the
[migration guide](../migration-v2.md) and
[compatibility reference](../reference/compatibility.md). The
[runtime implementation record](../implementations/20261122_v2_runtime_implementation.md)
describes the generated-only verification.
