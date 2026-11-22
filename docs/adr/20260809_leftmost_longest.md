# ADR: Select the longest match at each input position by default

- ステータス: 採用
- 決定日: 2026-08-09
- 関連: [Original decision](https://github.com/ydah/flexr/commit/5a4b46ae670376c4373e4b92e8cc80d4079ee691), [20261122_explicit_rule_priority.md / Decision](20261122_explicit_rule_priority.md#%E6%B1%BA%E5%AE%9A)

## コンテキスト

Two rules can start at the same byte and accept different lengths. If `=`
precedes `==` in a specification, either rule can accept the start of `==`.
`Flexr::Runtime::Interpreter#scan` compares accepting candidates by their
selection end. `followed_by:` contributes to that end while the token span
excludes the trailing context.

## 決定

Choose the longest accepted match from the current position. Use declaration
order to resolve equal lengths by default. For explicit priority, see the
decision in [20261122_explicit_rule_priority.md / Decision](20261122_explicit_rule_priority.md#%E6%B1%BA%E5%AE%9A).

## 検討した代替案

First-match selection makes the first `=` rule win on `==`. That behavior
helps port specifications whose rule order is part of their grammar, but it
would make the token boundaries of the default scanner depend on the order of
short and long rules.

## 影響

Users can add a longer operator without moving the shorter one to the end of
the specification. Changing the default could change token types and spans in
existing parsers. The compatibility backend described in
[20261122_stable_explicit_firstmatch.md / Decision](20261122_stable_explicit_firstmatch.md#%E6%B1%BA%E5%AE%9A)
lets callers explicitly use rule order for selection.
