# JSON lexer example

## What this example demonstrates

- a complete JSON token set with value conversion;
- the stable `direct` backend; and
- runtime/generated equivalence for a small practical lexer.

## Run in runtime mode

```sh
ruby -Ilib -e 'require "json"; load "examples/json/lexer.flexr.rb"; puts JSON.generate(JsonExample::Lexer.new(%q({"answer":42})).tokens)'
```

Expected output:

```json
[["LBRACE","{"],["STRING","answer"],["COLON",":"],["NUMBER",42.0],["RBRACE","}"]]
```

## Validate and generate

```sh
flexr check examples/json/lexer.flexr.rb --format json
flexr examples/json/lexer.flexr.rb -o /tmp/json_lexer.rb
ruby -Ilib -e 'require "json"; load ARGV.fetch(0); puts JSON.generate(JsonExample::Lexer.new(%q({"answer":42})).tokens)' /tmp/json_lexer.rb
```

The generated output should produce the same JSON token array. Use
`--standalone` when the runtime artifact must not require the flexr gem.
