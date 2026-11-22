# ADR: Use an internal Ruby DSL for lexer specifications

- ステータス: 採用
- 決定日: 2026-08-09
- 関連: [Original decision](https://github.com/ydah/flexr/commit/5a4b46ae670376c4373e4b92e8cc80d4079ee691), [20260809_static_analysis_by_default.md / Decision](20260809_static_analysis_by_default.md#%E6%B1%BA%E5%AE%9A)

## コンテキスト

Flexr users write token actions in Ruby. For example,
[the calculator specification](../../examples/calculator/lexer.flexr.rb)
declares rules with `Flexr::DSL#rule` in a `Flexr::Lexer` class. Rule actions
and helper methods use the same Ruby constants, scope, and tooling as the
application.

## 決定

Use ordinary Ruby source with an internal DSL for lexer definitions. Keep
Ruby class bodies, constants, methods, `require` statements, comments, and
action blocks available to specification authors.

## 決定しないこと

The generator's static evaluation boundary is the decision in
[20260809_static_analysis_by_default.md / Decision](20260809_static_analysis_by_default.md#%E6%B1%BA%E5%AE%9A).

## 検討した代替案

A separate specification grammar could constrain the syntax more tightly.
It would need its own parser and a convention for embedding and locating
Ruby actions. A Ruby DSL lets users keep their existing source and tools.

## 影響

A specification is executable Ruby when loaded. Users can work with it
through ordinary Ruby tooling. Changing to an external grammar would require
migrating lexer source and integration code.
