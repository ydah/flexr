---
title: Tokens and locations
description: Return shapes, semantic values, and source positions.
---

`token_kind` controls how the lexer exposes a token:

| `token_kind` | `next_token` | `each_token` |
| --- | --- | --- |
| `:array` | `[type, value]` | Yields one array |
| `:struct` | `Flexr::Runtime::Token` | Yields a token |
| `:yield` | Adapter-defined | Yields `type, value` |

Locations use byte offsets for the input position and track line/column as the lexer consumes text. Keep the location with the token when a parser needs useful syntax errors.

For exact defaults and the `Location` data structure, use the repository's [tokens and locations reference](https://github.com/ydah/flexr/blob/main/docs/reference/tokens-and-locations.md).
