# ADR: Insert reusable rules at each explicit use site

- ステータス: 採用
- 決定日: 2026-11-22
- 関連: [#88](https://github.com/ydah/flexr/pull/88), [20261122_explicit_rule_priority.md / Decision](20261122_explicit_rule_priority.md#%E6%B1%BA%E5%AE%9A)

## コンテキスト

Source order breaks ties between Flexr rules of equal match length and
priority. A shared rules module may contain a rule that overlaps one declared
in the consuming lexer. The position of its expansion determines which
token wins without changing either pattern.

## 決定

Define reusable rules in modules extended with `Flexr::Rules`. A consuming
lexer explicitly inserts a snapshot of the rule declarations at `use`.
They participate in the caller's active states, priority, and channel
semantics. Preserve the Ruby bindings of their actions. Lexer subclasses
start with their own rules and state declarations.

## 決定しないこと

The generator's handling of supported source declarations and binding actions
is described in [the static rule-set expansion notes](../implementations/20261122_static_rule_set_expansion.md).

## 検討した代替案

Inheriting rules implicitly would make the winning rule depend on declaration
order in another class. A shared module inserted at the front or back by
default would also prevent a caller from choosing its placement among
overlapping rules.

## 影響

Moving a `use` call can change the result of an equal-priority tie, just as
moving a direct rule can. A subclass must state each reuse explicitly.
Static generation requires named rule sets declared in the same file.
See the [rule-set reference](../reference/dsl.md#userule_set).
