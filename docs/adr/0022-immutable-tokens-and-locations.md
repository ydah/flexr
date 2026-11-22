# ADR 0022: Make structured tokens and locations immutable

## Context

Tokens describe what the lexer emitted and locations describe the span it
consumed. Mutable `Struct` fields let consumers rewrite those records after
emission. Locations also need to support lazy column readers without retaining
the lexer.

## Decision

Use Ruby `Data` for `Token` and `Location`. Keep `token_kind :struct` as the
option that selects these records and preserve attribute readers, keyword
construction, and read-only indexing. Consumers use `with` to create a record
with changed fields. The default `:array` token format remains available.

Store lazy columns in a frozen pair so reading them needs neither the lexer
nor record mutation. Record immutability is shallow. An action that emits a
mutable value leaves ownership of that value with the application.

See the [token and location reference](../reference/tokens-and-locations.md)
and the [migration guide](../migration-v2.md#immutable-tokens-and-locations).
