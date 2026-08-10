# Handle errors

There are two error layers: specification diagnostics and input-time lexical
errors.

## Validate the specification

```sh
flexr check lexer.flexr.rb --format json --warn all
```

The command returns status 0 when the specification compiles, even when it has
warnings. Add `--warn-as-error` in CI to make warnings fail the check. Syntax,
unsupported regexp, and compile-limit failures return status 1; malformed CLI
usage returns status 2.

## Choose input error behavior

```ruby
Lexer.new(input, error_mode: :raise)
Lexer.new(input, error_mode: :token)
Lexer.new(input, error_mode: :panic)
```

`:raise` raises `Flexr::LexError`, `:token` emits `[:error, text]`, and `:panic`
skips the unmatched byte and continues. You can override the decision for one
instance with `lexer.on_error = ->(error) { :skip }`, `:raise`, `:token`, or
`:halt`. The callback receives the `LexError` and may inspect its filename,
byte position, line, and text.

`error!` creates the same error from an action. `max_token_size` protects the
runtime from unexpectedly large tokens and raises `FLEXR-E012` when exceeded.
