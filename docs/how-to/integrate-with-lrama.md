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
