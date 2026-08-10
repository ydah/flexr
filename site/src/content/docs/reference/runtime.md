---
title: Runtime reference
description: The runtime entry points and operational behavior.
---

Create a lexer with an input string or IO-like source, then call `next_token` or `each_token`.

```ruby
lexer = Lexer.new(source)
token = lexer.next_token
lexer.each_token { |type, value| consume(type, value) }
```

The runtime tracks byte position, line, column, and the last token location. Buffering and encoding behavior follow the options declared by the lexer. EOF is represented by the runtime's end-of-input result and should be normalized by a parser adapter.

See the repository's [runtime reference](https://github.com/ydah/flexr/blob/main/docs/reference/runtime.md) for constructor options, `less`, `more`, `echo`, state transitions, and error hooks.
