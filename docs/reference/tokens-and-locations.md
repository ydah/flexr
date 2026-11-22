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

In v2, `Token` and `Location` are immutable `Data` records. The `:struct`
option name is retained. Attribute readers and read-only indexing by member
name or index remain available; field writers and `[]=` are removed. Replace
values with `token.with(value: replacement)` or `location.with(...)`.
Immutability is shallow: custom token values can still be mutable.
Lazy columns use a frozen pair without mutating the record or retaining the
lexer; `to_h` returns the resolved columns.

## Trivia channels

Retain whitespace and comments in named channels when writing a formatter or
source tool alongside a parser.

```ruby
class Lexer < Flexr::Lexer
  token_kind :struct
  rule(/#[^\n]*/, channel: :comment)
  rule(/[ \t\n]+/, channel: :whitespace)
  rule(/[a-z_][a-z0-9_]*/, emit: :IDENT)
end

input = "# note\nname"
token = Lexer.new(input).next_token
token.leading_trivia.map(&:channel) # => [:comment, :whitespace]
Lexer.new(input).tokens(channels: :all).map(&:value).join == input # => true
```

Structured tokens expose their `channel` and a frozen `leading_trivia` array
of structured tokens. The array contains the trivia between this token
and the previous default-channel token. An emitted EOF token can carry
any trailing trivia. Use `tokens(channels: :all)` to collect trailing trivia
when there is no EOF token. Lexical error recovery tokens and EOF emissions
use the default channel. For `more`, the rule that emits the combined text
determines its channel. `Token#with` preserves this metadata, and its
three data members stay the same. Array and yield tokens retain their
two-element shape.

Joining values reconstructs the original input when rules preserve the
matched text, retain every byte, and emit it once. Discard rules, actions
that change values, and synthesized tokens can alter the reconstructed text.

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
