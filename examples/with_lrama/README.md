# flexr with Lrama

## What this example demonstrates

Lrama consumes the same `racc_next_token` protocol as Racc. The lexer declares
grammar-facing names with `emits`, and the dependency on Lrama remains optional.

## Run and validate

```sh
ruby -Ilib -e 'load "examples/with_lrama/lexer.flexr.rb"; lexer = WithLrama::LramaLexer.new("12 - 3"); p lexer.tokens'
flexr tokens examples/with_lrama/lexer.flexr.rb
flexr check examples/with_lrama/lexer.flexr.rb --format json
```

See the [Lrama integration guide](../../docs/how-to/integrate-with-lrama.md)
for the EOF protocol and build flow.
