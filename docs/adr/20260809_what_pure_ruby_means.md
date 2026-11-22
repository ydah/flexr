# ADR: Run lexers with Ruby and its standard library

- ステータス: 採用
- 決定日: 2026-08-09
- 関連: [Original decisions](https://github.com/ydah/flexr/commit/5a4b46ae670376c4373e4b92e8cc80d4079ee691)

## コンテキスト

Runtime mode receives Ruby `Regexp` and `Proc` objects from the evaluated DSL.
The ahead-of-time generator starts with source text and needs positions in
that source to preserve user Ruby while replacing DSL declarations.
`Flexr::Source::PrismReader#read` uses Prism for that task. Loading
`flexr/runtime` does not load the source reader.

## 決定

Keep flexr's runtime and the runtime embedded in generated lexers on Ruby's
standard library. Use Prism in tooling that reads specifications, including
ahead-of-time generation. Normal generated lexers load the flexr runtime.
Standalone generated lexers embed their runtime.

## 決定しないこと

Applications supply the dependencies used by their own Ruby actions. See the
decision in [20260809_spec_is_plain_ruby.md / Decision](20260809_spec_is_plain_ruby.md#%E6%B1%BA%E5%AE%9A).

## 検討した代替案

A shared source-reading path would require Prism in deployments. The
runtime already receives the expressions and actions it needs from evaluated
declarations, and deployments of ahead-of-time generated lexers would carry
an unused parser dependency.

## 影響

Users install Prism where they generate code. They can deploy a standalone
lexer as a single file on a compatible Ruby. Runtime features and optional
accelerators must remain available within that deployment boundary. The
[dependency matrix](../reference/generated-artifacts.md#dependency-matrix)
defines the requirements for each mode.
