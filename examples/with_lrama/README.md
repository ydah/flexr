# flexr with Lrama

## What this example demonstrates

The lexer declares grammar-facing names with `emits`. The example runs the
Ruby lexer and shows the token kinds and values available to a parser.

## Run and validate

```sh
ruby -Ilib -e 'load "examples/with_lrama/lexer.flexr.rb"; lexer = WithLrama::LramaLexer.new("12 - 3"); p lexer.tokens'
flexr tokens examples/with_lrama/lexer.flexr.rb
flexr check examples/with_lrama/lexer.flexr.rb --format json
```

See the [Lrama integration guide](../../docs/how-to/integrate-with-lrama.md)
for the C parser build flow and a complete calculator project.
