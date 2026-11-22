# Build a calculator parser in five minutes

Start with Ruby 3.4 or later, Bundler, and a version of flexr that provides
`flexr new --help`. Choose one parser and run its commands in the directory
where you want the new project.

## Racc

```sh
flexr new my-calculator --parser racc
cd my-calculator
bundle install
bundle exec rake test
bundle exec ruby calculator.rb '12 + 3 - 4'
```

The calculator prints `11`. Racc generates a Ruby parser that pulls one
token and value at a time from the Flexr lexer.

## Lrama

Install a C compiler and make it available as `cc`, or set `CC` to its
executable.

```sh
flexr new my-calculator --parser lrama
cd my-calculator
bundle install
bundle exec rake test
bundle exec ruby calculator.rb '12 + 3 - 4'
```

The calculator prints `11`. Lrama generates a C parser. The Ruby driver
starts the compiled parser and sends it the tokens produced by Flexr.
This calculator accepts integer tokens and results in the signed 64-bit
range.

## Change the grammar

Start with `lexer.flexr.rb` to see how input becomes `INTEGER`, `PLUS`, and
`MINUS` tokens. Open `parser.y` to see the rules that combine those tokens
into an expression. When adding an operator, declare the same token name in
both files and add an example to `test_calculator.rb`.

Run `bundle exec rake test` after each change. It rebuilds the parser when
the grammar changes. Run `bundle exec rake build` to rebuild without running
the tests.
