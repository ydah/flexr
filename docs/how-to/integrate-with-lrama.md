# Integrate with Lrama

Lrama-generated parsers use the same two-element token protocol as Racc.
Implement the lexer with `racc_next_token`, declare the grammar tokens with
`emits`, and generate the lexer as part of the parser build.

```ruby
class Lexer < Flexr::Lexer
  emits :INTEGER, :MINUS
  rule(/[ \t\r\n]+/, skip: true)
  rule(/[0-9]+/, emit: :INTEGER)
  rule(/-/, emit: :MINUS)
end
```

`racc_next_token` returns `[type, value]` for a token and `[false, "$end"]` at
EOF. `emits` is a documentation and diagnostic contract; it does not alter
the value returned by the lexer.

See the runnable [Lrama example](../../examples/with_lrama/README.md) and the
[token contract](../reference/tokens-and-locations.md).
