# Toy language lexer

## What this example demonstrates

This lexer keeps `DIGIT` and `IDENT` as ordinary Ruby constants and interpolates
them into regexp literals. It therefore exercises static constant resolution
without introducing a second lexer language.

## Run and validate

```sh
ruby -Ilib -e 'require "json"; load "examples/toy_lang/lexer.flexr.rb"; puts JSON.generate(ToyLang::Lexer.new("answer + 12").tokens)'
flexr check examples/toy_lang/lexer.flexr.rb --format json
flexr examples/toy_lang/lexer.flexr.rb -o /tmp/toy_lang_lexer.rb
```

The generated file preserves the constants and produces the same token stream.
