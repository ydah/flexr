# Integrate with Racc

flexr exposes the conventional `racc_next_token` method, so a parser can use a
lexer without an adapter:

```ruby
class Lexer < Flexr::Lexer
  emits :INTEGER, :PLUS
  rule(/[ \t\r\n]+/, skip: true)
  rule(/[0-9]+/, emit: :INTEGER)
  rule(/\+/, emit: :PLUS)
end

lexer = Lexer.new("12 + 3")
lexer.racc_next_token # => [:INTEGER, "12"]
```

At EOF the method returns `[false, "$end"]`. Keep the names in `emits` aligned
with the grammar's `%token` declarations. `flexr tokens SPEC.flexr.rb` prints
the declared names for a build-time comparison.

The complete executable lexer is in
[examples/with_racc](../../examples/with_racc/README.md). Generate the lexer
before running a parser build if the parser should consume a committed Ruby
artifact.
