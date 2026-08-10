# Use trailing context

Use `followed_by:` when a rule should be selected only if another expression
starts immediately after it, but that expression must remain in the input for
the next token:

```ruby
class Lexer < Flexr::Lexer
  rule(/name/, followed_by: /\(/) { emit :CALL }
  rule(/[a-z_][a-z0-9_]*/) { emit :IDENT }
  rule(/\(/) { emit :LPAREN }
end
```

The input `name(` produces `CALL` for `name`, then `LPAREN` for `(`. A string
can be used for literal trailing context. The body and trailing expression
should be fixed length when possible; variable-length context produces
`FLEXR-W003` and can prevent region acceleration (`FLEXR-W012`).

Trailing context is not the same as regexp lookahead. Lookahead syntax is
rejected with `FLEXR-E014`; `followed_by:` is the supported replacement.
Disable acceleration with `accel :none` only when the trade-off is understood.
