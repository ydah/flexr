# ADR: Use an internal Ruby DSL for lexer specifications

- Status: Accepted
- Decision date: 2026-08-09
- Related: [Original decision](https://github.com/ydah/flexr/commit/5a4b46ae670376c4373e4b92e8cc80d4079ee691), [20260809_static_analysis_by_default.md / Decision](20260809_static_analysis_by_default.md#decision)

## Context

Flexr users write token actions in Ruby. For example,
[the calculator specification](../../examples/calculator/lexer.flexr.rb)
declares rules with `Flexr::DSL#rule` in a `Flexr::Lexer` class. Rule actions
and helper methods use the same Ruby constants, scope, and tooling as the
application.

## Decision

Use ordinary Ruby source with an internal DSL for lexer definitions. Keep
Ruby class bodies, constants, methods, `require` statements, comments, and
action blocks available to specification authors.

## Out of scope

The generator's static evaluation boundary is the decision in
[20260809_static_analysis_by_default.md / Decision](20260809_static_analysis_by_default.md#decision).

## Alternatives considered

A separate specification grammar could constrain the syntax more tightly.
It would need its own parser and a convention for embedding and locating
Ruby actions. A Ruby DSL lets users keep their existing source and tools.

## Consequences

A specification is executable Ruby when loaded. Users can work with it
through ordinary Ruby tooling. Changing to an external grammar would require
migrating lexer source and integration code.
