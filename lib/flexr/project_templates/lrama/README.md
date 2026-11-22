# Lrama calculator

Use Ruby 3.4 or later and a C compiler named `cc`. Set `CC` to use a different
compiler executable.

```sh
bundle install
bundle exec rake test
bundle exec ruby calculator.rb '12 + 3 - 4'
```

The calculator prints `11`. The lexer in `lexer.flexr.rb` produces tokens.
`calculator.rb` passes their kinds and values to the compiled parser. Lrama
generates C from `parser.y`. The parser accepts results and integer tokens in
the signed 64-bit range.

Run `bundle exec rake build` to generate and compile the parser.
