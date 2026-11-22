# Racc calculator

Run these commands with Ruby 3.4 or later:

```sh
bundle install
bundle exec rake test
bundle exec ruby calculator.rb '12 + 3 - 4'
```

The calculator prints `11`. The lexer in `lexer.flexr.rb` turns input into
tokens. Racc builds a Ruby parser from `parser.y` and uses the lexer's
`racc_next_token` method to read those tokens.

Run `bundle exec rake build` to regenerate the parser without running tests.
