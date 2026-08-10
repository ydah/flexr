# Build a calculator lexer

This tutorial takes one specification through runtime execution, diagnostics,
generation, and generated execution. The complete executable source is
[`examples/calculator/lexer.flexr.rb`](../../examples/calculator/lexer.flexr.rb).

## 1. Install flexr

```sh
gem install flexr
```

For a checkout, use the bundle and add `lib` to Ruby's load path:

```sh
bundle install
bundle exec ruby -Ilib examples/calculator/lexer.flexr.rb
```

## 2. Read the specification

```ruby
class Lexer < Flexr::Lexer
  emits :EQ, :ASSIGN, :IF, :IDENT, :INTEGER, :PLUS

  rule(/[ \t\r\n]+/, skip: true)
  rule(/==/) { emit :EQ }
  rule(/=/) { emit :ASSIGN }
  rule(/if/) { emit :IF }
  rule(/[a-z_][a-z0-9_]*/) { emit :IDENT }
  rule(/[0-9]+/) { emit :INTEGER, text.to_i }
  rule(/\+/) { emit :PLUS }
end
```

`emits` is a declaration used by diagnostics and parser integration. It does
not create constants and is not required for `emit` to work.

The `==` rule is longer than `=`, so it wins even though both rules are active.
The input `if` matches both the keyword and identifier rules with equal length;
the keyword rule appears first, so it wins. The input `ifx` is longer under the
identifier rule and therefore becomes one identifier token.

## 3. Run runtime mode

```sh
ruby -Ilib -e 'require "json"; load "examples/calculator/lexer.flexr.rb"; puts JSON.generate(CalculatorExample::Lexer.new("if ifx == = 12 + 3").tokens)'
```

Expected output:

```json
[["IF","if"],["IDENT","ifx"],["EQ","=="],["ASSIGN","="],["INTEGER",12],["PLUS","+"],["INTEGER",3]]
```

Runtime mode evaluates the Ruby specification normally. The DFA is compiled
when the lexer class is first used, and actions run in the lexer instance.

## 4. Validate the specification

```sh
flexr check examples/calculator/lexer.flexr.rb --format json
```

An empty JSON array means that the specification produced no errors or selected
warnings. Use `--warn all` to include the full warning catalog.

## 5. Generate Ruby

```sh
flexr examples/calculator/lexer.flexr.rb -o /tmp/calculator_lexer.rb
```

The default generator statically resolves patterns and constants with Prism.
The generated file keeps ordinary Ruby surrounding the DSL, embeds the
compiled tables, and keeps actions as Ruby code.

## 6. Run the generated lexer

```sh
ruby -Ilib -e 'require "json"; load ARGV.fetch(0); puts JSON.generate(CalculatorExample::Lexer.new("if ifx == = 12 + 3").tokens)' /tmp/calculator_lexer.rb
```

The output must match runtime mode. `rake modes:equivalence` checks this
relationship for every committed example.

## 7. Inspect the contract

```sh
flexr tokens examples/calculator/lexer.flexr.rb
flexr stats examples/calculator/lexer.flexr.rb
flexr explain examples/calculator/lexer.flexr.rb --rule 1
```

Use the [DSL reference](../reference/dsl.md) for method arguments and the
[CLI reference](../reference/cli.md) for output and exit-status behavior.
