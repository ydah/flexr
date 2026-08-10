# Ruby subset lexer

## What this example demonstrates

The specification contains constants, a `%w` array, a heredoc inside an action,
and ordinary Ruby interpolation. The generator removes only DSL calls and
preserves the surrounding Ruby.

## Run and validate

```sh
ruby -Ilib -e 'require "json"; load "examples/ruby_subset/lexer.flexr.rb"; puts JSON.generate(RubySubset::Lexer.new(%q(class Foo "ok" end)).tokens)'
flexr check examples/ruby_subset/lexer.flexr.rb --format json
flexr examples/ruby_subset/lexer.flexr.rb -o /tmp/ruby_subset_lexer.rb
```

Inspect the generated file to see that the constants and action body remain.
