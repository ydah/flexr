# Runtime reference

`Flexr::Lexer` includes the runtime methods below. Runtime mode and generated
mode expose the same consumer-facing methods.

## Initialization

```ruby
Lexer.new(input,
  filename: nil,
  error_mode: :raise,
  max_token_size: 16 * 1024 * 1024,
  max_lookahead_size: nil,
  max_buffer_size: 64 * 1024 * 1024,
  max_state_stack: 1024,
  max_steps: nil,
  cancellation: nil,
  retain_input: true,
  chunk_size: 64 * 1024)
```

`input` must be a `String` or an object responding to `read`. `filename` is
copied into locations and lexical errors. `error_mode` is `:raise`, `:token`,
or `:panic`; unknown values fall back to raising when an unmatched byte is
handled. `max_lookahead_size` defaults to `max_token_size`. `max_steps: nil`
leaves the step count unbounded; `cancellation` may be a callable accepting
zero arguments or the lexer. Size limits are non-negative, and `chunk_size`
must be positive.

## Consumption

| Method | Result |
|---|---|
| `next_token` | One token, or `nil` at EOF |
| `tokens` | Array containing every token until EOF |
| `each_token` | Enumerator without a block; otherwise yields tokens and returns `self` |
| `racc_next_token` | `[type, value]`, or `[false, "$end"]` at EOF |
| `input` | The currently retained input string |
| `buffer` | Internal buffered input object; use only for integrations that need it |
| `filename` | The configured filename |
| `error_mode` | The configured default input error mode |
| `max_token_size` | The configured token-size limit |
| `max_lookahead_size` | The configured trailing-context limit |
| `steps` | Work units consumed by scanning |

`each_token` yields two arguments instead of one when `token_kind :yield` is
selected. `tokens` always returns an array of token values.

## State and action context

The public action methods are collected in the [actions reference](actions.md).
State transitions are instance-local; changing one lexer does not change the
class or another lexer instance.

## Streaming input

IO input is read lazily in chunks. UTF-8 input is checked at codepoint
boundaries, while binary input is consumed byte by byte. Invalid UTF-8 becomes
an unmatched-byte error rather than being silently normalized. With
`retain_input: false`, bytes before the current token are released after each
match; `input` and `binary_input` then expose only the retained window.

`max_token_size` is checked before an action can shorten or materialize an
oversized match. `max_lookahead_size` separately bounds trailing context, and
`max_buffer_size` bounds bytes retained at one time. `max_steps` and
`cancellation` bound CPU work cooperatively.
