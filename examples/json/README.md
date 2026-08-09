# JSON lexer example

`lexer.flexr.rb` is an ordinary Ruby file. It works directly at runtime:

```ruby
require_relative "lexer.flexr"
JsonExample::Lexer.new('{"answer": 42}').tokens
```

It can also be transformed into a generated Ruby file with `flexr`.
