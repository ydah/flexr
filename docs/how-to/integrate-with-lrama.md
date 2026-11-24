# Integrate with Lrama

Lrama generates a C parser that reads tokens from its C `yylex` function.
The Flexr lexer supplies the token kinds and values. A Ruby driver can send
those pairs to the compiled parser, as in the generated calculator project.

```ruby
class Lexer < Flexr::Lexer
  emits :INTEGER, :MINUS
  rule(/[ \t\r\n]+/, skip: true)
  rule(/[0-9]+/, emit: :INTEGER)
  rule(/-/, emit: :MINUS)
end
```

Keep the names in `emits` aligned with the grammar's `%token` declarations.
Use `flexr check lexer.flexr.rb --grammar parser.y` to compare the names.

Generate a working project with `flexr new NAME --parser lrama`.
The [calculator tutorial](../tutorial/build-a-calculator-parser.md#lrama)
shows how to build and test it with a C compiler. The [lexer example](../../examples/with_lrama/README.md)
shows how to inspect the token stream.

## Use parser state contexts

Install Lrama 0.8 alongside Flexr in the build environment. Generate the
lexer and parser from the same grammar so their LR state numbers agree.
[Lrama 0.8.0](https://rubygems.org/gems/lrama/versions/0.8.0)

```sh
flexr --lrama-grammar parser.y --standalone -o lexer.rb lexer.flexr.rb
```

Pass the current LR state to the lexer when the parser requests a token.
In an Lrama C parser, the `yylex` call runs in the scope of `yystate`. The
adapter that forwards the lexer request to Ruby can pass that value as
`state_id`.

```ruby
lexer.next_token(parser_state: state_id)
```

Flexr shares identical terminal sets and attaches the selected set's rule
mask to each request. The emitted lexer carries the data it needs to scan
without Lrama. Named grammar terminals use their declared names as Ruby
symbols. Literal terminals such as `'+'` use `:+`. The lexer returns `nil`
at EOF, and the parser adapter supplies the parser's EOF token.

The terminal set includes states where the parser can reduce using the
requested token. A default reduction admits terminals that reach that
default action. The parser still validates the resulting token against its
stack. For rule actions, channels, and keyword tables, the same
[eligibility rules as `expect:`](../reference/runtime.md#parser-token-expectations)
apply.

Before generating the lexer, check whether two eligible terminals tie at the
winning match length in any LR state.

```sh
flexr check lexer.flexr.rb --lrama-grammar parser.y --warn-as-error
```

A tie report includes an example input and a grammar-symbol path to the LR
state. See [the diagnostic details](../reference/cli.md#check-parser-state-ambiguity).
