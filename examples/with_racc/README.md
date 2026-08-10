# flexr with Racc

## What this example demonstrates

`RaccLexer` exposes the two-element `racc_next_token` protocol expected by Racc.
The parser dependency is intentionally optional in this repository.

## Run and inspect

```sh
ruby -Ilib -e 'load "examples/with_racc/lexer.flexr.rb"; lexer = WithRacc::RaccLexer.new("12 + 3"); p lexer.racc_next_token; p lexer.racc_next_token; p lexer.racc_next_token; p lexer.racc_next_token'
flexr tokens examples/with_racc/lexer.flexr.rb
flexr check examples/with_racc/lexer.flexr.rb --format json
```

Compare the names printed by `flexr tokens` with the grammar's `%token` list.
See the [Racc integration guide](../../docs/how-to/integrate-with-racc.md).
