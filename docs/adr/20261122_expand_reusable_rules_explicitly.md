# ADR: Insert reusable rules at each explicit use site

- Status: Accepted
- Decision date: 2026-11-22
- Related: [#88](https://github.com/ydah/flexr/pull/88), [20261122_explicit_rule_priority.md / Decision](20261122_explicit_rule_priority.md#decision)

## Context

Source order breaks ties between Flexr rules of equal match length and
priority. A shared rules module may contain a rule that overlaps one declared
in the consuming lexer. The position of its expansion determines which
token wins without changing either pattern.

## Decision

Define reusable rules in modules extended with `Flexr::Rules`. A consuming
lexer explicitly inserts a snapshot of the rule declarations at `use`.
They participate in the caller's active states, priority, and channel
semantics. Preserve the Ruby bindings of their actions. Lexer subclasses
start with their own rules and state declarations.

## Out of scope

The generator's handling of supported source declarations and binding actions
is described in [the static rule-set expansion notes](../implementations/20261122_static_rule_set_expansion.md).

## Alternatives considered

Inheriting rules implicitly would make the winning rule depend on declaration
order in another class. A shared module inserted at the front or back by
default would also prevent a caller from choosing its placement among
overlapping rules.

## Consequences

Moving a `use` call can change the result of an equal-priority tie, just as
moving a direct rule can. A subclass must state each reuse explicitly.
Static generation requires named rule sets declared in the same file.
See the [rule-set reference](../reference/dsl.md#userule_set).
