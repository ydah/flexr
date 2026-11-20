# TOML subset lexer

Tokenizes bare names, single-line quoted strings, decimal numbers, booleans,
tables, inline tables, arrays, and comments. Values remain source text.
This is a lexer example, not a TOML validator: multiline strings, date/time
values, non-decimal numbers, and escape decoding need additional rules or a parser.

```sh
ruby -Ilib -e 'load "examples/toml/lexer.flexr.rb"; p TomlExample::Lexer.new(%q(title = "flexr")).tokens'
bundle exec ruby benchmark/run.rb --spec examples/toml/lexer.flexr.rb --iterations 1 --json
```

The benchmark uses a repeated built-in document fragment and compares runtime
with generated mode. Pass `--input-file PATH` to measure a different corpus.
