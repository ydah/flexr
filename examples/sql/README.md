# SQL subset lexer

Tokenizes a small set of case-insensitive SQL keywords, unquoted names, decimal
numbers, single-quoted strings (including doubled quotes), line comments, and
operators. Keywords are uppercased; other values remain source text. Longest
match keeps `select_name` as one name and `>=` as one operator.
Quoted identifiers, block comments, vendor-specific syntax, and SQL grammar
validation are outside this example. Never use this lexer to sanitize SQL.

```sh
ruby -Ilib -e 'load "examples/sql/lexer.flexr.rb"; p SqlExample::Lexer.new("select name from users where id >= 12;").tokens'
bundle exec ruby benchmark/run.rb --spec examples/sql/lexer.flexr.rb --iterations 1 --json
```

The benchmark uses a repeated built-in query and compares runtime with generated
mode. Pass `--input-file PATH` to measure a different corpus.
