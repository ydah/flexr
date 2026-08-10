# Track token locations

Use `token_kind :struct` when consumers need a value object with a location:

```ruby
class Lexer < Flexr::Lexer
  token_kind :struct
  option :eager_columns

  rule(/[0-9]+/) { emit :INTEGER, text.to_i }
end

token = Lexer.new("12\n34").next_token
token.type
token.value
token.location.line_begin
token.location.column_begin
```

Locations use byte offsets for `byte_begin` and `byte_end`, with an exclusive
end offset. Lines and columns are one-based. UTF-8 columns count characters;
binary columns count bytes. Column values are computed lazily unless
`option :eager_columns` is set. `filename:` on the lexer is copied into each
location and lexical error.

`more` joins successive matches into one `text` value, so `last_location` spans
the complete assembled token. See the [token and location contract](../reference/tokens-and-locations.md).
