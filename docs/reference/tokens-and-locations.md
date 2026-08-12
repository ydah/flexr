# Tokens and locations

## Token kinds

| `token_kind` | `next_token` / `tokens` | `each_token` |
|---|---|---|
| `:array` (default) | `[type, value]` | Yields one array |
| `:struct` | `Flexr::Runtime::Token` | Yields one `Token` |
| `:yield` | `[type, value]` | Yields `type, value` as separate arguments |

For `:struct`, `Token` has `type`, `value`, and `location` members. `emit(nil,
value)` is valid and produces a token whose type is `nil`. `skip` produces no
token.

## Locations

`Flexr::Runtime::Location` has these public members:

| Member | Meaning |
|---|---|
| `filename` | The `filename:` value passed to the lexer |
| `byte_begin` | Inclusive byte offset of the token |
| `byte_end` | Exclusive byte offset of the token |
| `line_begin` / `line_end` | One-based line range |
| `column_begin` / `column_end` | One-based character columns for UTF-8, byte columns for binary input |

Line and column positions are tracked incrementally while input is consumed,
so creating locations does not rescan the input prefix. Column members are
filled lazily by default; `option :eager_columns` fills them while the location
is created. The end line and column identify the position after the token's
last byte, so a token ending at the start of the next line may have an end
column of 1.

`more` extends the location from the first match to the final match. Trailing
context is not part of the location because it is not consumed.
