# GraphQL subset lexer

Tokenizes names, numbers, single-line strings, comments, ignored commas, spread,
variables, directives, and punctuation. Keywords remain `NAME` tokens so the
parser can interpret them by context. Values remain source text.
Block strings, escape validation, and grammar validation are outside this example.

```sh
ruby -Ilib -e 'load "examples/graphql/lexer.flexr.rb"; p GraphqlExample::Lexer.new("query { user(id: 12) { name } }").tokens'
bundle exec ruby benchmark/run.rb --spec examples/graphql/lexer.flexr.rb --iterations 1 --json
```

The benchmark uses a repeated built-in query and compares runtime with generated
mode. Pass `--input-file PATH` to measure a different corpus.
