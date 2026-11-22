# ADR: Support first-match selection as a stable explicit backend

- ステータス: 採用
- 決定日: 2026-11-22
- 関連: [#65](https://github.com/ydah/flexr/pull/65), [#32](https://github.com/ydah/flexr/pull/32), [20260809_leftmost_longest.md / Decision](20260809_leftmost_longest.md#%E6%B1%BA%E5%AE%9A)

## コンテキスト

Ported specifications may depend on source order. If `/a/` precedes `/ab/`,
first-match selection consumes `a` from `ab`. The default longest match
consumes `ab`. Flexr 1.1.0 exposed both choices and required
`option :experimental` for `:firstmatch` in `Flexr::Automaton::Compiler`.

## 決定

Make `backend :firstmatch` a stable opt-in for runtime and generated lexers.
Select the first matching rule in source order and honor Ruby regexp
alternative order within that rule. Continue accepting `option :experimental`
in older specifications. Keep `table`, `direct`, and `auto` on the matching
contract in [20260809_leftmost_longest.md / Decision](20260809_leftmost_longest.md#%E6%B1%BA%E5%AE%9A).

## 検討した代替案

Continuing to gate `firstmatch` would leave migration users without a stable
rule-order contract. Making it the default would change matches and spans
for existing longest-match lexers.

## 影響

Applications can port ordering-sensitive rules without relying on an
experimental feature. `FLEXR-W010` reports potential token selection
differences from longest match. Rule and regexp ordering become part of the
public contract for this backend.
