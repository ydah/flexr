# ADR: Make structured tokens and locations immutable Ruby Data records

- ステータス: 採用
- 決定日: 2026-11-22
- 関連: [#65](https://github.com/ydah/flexr/pull/65), [#40](https://github.com/ydah/flexr/pull/40)

## コンテキスト

`Flexr::Runtime::Token` and `Flexr::Runtime::Location` were mutable `Struct`
records in flexr 1.2.0. Consumers could rewrite the recorded token or source
span after emission. Location columns also need to stay readable without
retaining the lexer.

## 決定

Define `Token` and `Location` with Ruby `Data`. Keep `token_kind :struct`,
attribute readers, keyword construction, and read-only indexing. Use `with`
to return a copy with different fields. Keep array tokens available as the
default token format.

## 検討した代替案

Keeping mutable `Struct` records would preserve field setters but would let
a consumer change the record other consumers see. Freezing a `Struct` would
reject mutation at runtime and still require a separate copying API.

## 影響

Structured tokens and locations preserve the emitted fields. Code that set
those fields must construct a replacement. Immutability is shallow so the
application retains ownership of a mutable token value. See the
[token and location reference](../reference/tokens-and-locations.md) and
[migration guide](../migration-v2.md#immutable-tokens-and-locations). The
[runtime implementation record](../implementations/20261122_v2_runtime_implementation.md)
describes how location readers avoid retaining the lexer.
