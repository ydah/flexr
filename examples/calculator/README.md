# Calculator lexer example

This is the executable source for the first-time user tutorial. It keeps the
rules deliberately small while showing two important matching contracts:

- `==` wins over `=` because the longest match wins.
- `if` wins over the identifier rule for the input `if` because equal-length
  matches use source order.

Run it directly:

```sh
ruby -Ilib -e 'require "json"; load "examples/calculator/lexer.flexr.rb"; puts JSON.generate(CalculatorExample::Lexer.new("if ifx == = 12 + 3").tokens)'
```

Expected output:

```json
[["IF","if"],["IDENT","ifx"],["EQ","=="],["ASSIGN","="],["INTEGER",12],["PLUS","+"],["INTEGER",3]]
```

Validate and generate it with:

```sh
flexr check examples/calculator/lexer.flexr.rb --format json
flexr examples/calculator/lexer.flexr.rb -o /tmp/calculator_lexer.rb
```
