# Run a lexer at runtime

Runtime mode loads the Ruby specification and builds its automaton when the
lexer class is first used. It is the simplest mode for development and tests.

```ruby
require "flexr"

class Lexer < Flexr::Lexer
  rule(/[ \t\n]+/, skip: true)
  rule(/[0-9]+/) { emit :INTEGER, text.to_i }
end

lexer = Lexer.new(StringIO.new("12 34"))
lexer.each_token { |token| p token }
```

The input may be a `String` or an object responding to `read`. IO input is read
in chunks; `chunk_size:` controls the buffer size. `next_token` returns one
token or `nil` at EOF, `tokens` drains the lexer into an array, and
`each_token` returns an enumerator when no block is given.

For a long-lived stream that does not need old input, pass
`retain_input: false`. Combine it with `max_buffer_size:`, `max_token_size:`,
and `max_lookahead_size:` to keep memory bounded. Use `max_steps:` or a
`cancellation:` callback when request-level work must also be bounded.

Use runtime mode when the specification deliberately depends on ordinary Ruby
execution. Static generation is a better fit when startup cost, deployment
reproducibility, or a generator-free runtime matters.

See the [runtime reference](../reference/runtime.md) for initialization options
and the [action reference](../reference/actions.md) for methods available in a
rule block.

## Feed chunks from an application

Build a push lexer when your application owns the input loop.

```ruby
lexer = Lexer.push
lexer.feed("12") { |token| p token }
lexer.feed(" 34") { |token| p token }
lexer.finish { |token| p token }
```

The second call can emit `12` once it sees the space. The final call emits
`34` at EOF. A socket reader can call `feed` for each chunk and `finish` when
the peer closes the stream. Token callbacks run in the reader's fiber.

See [the framing examples](../../examples/push_streams.rb) for split HTTP
request lines and headers, Redis RESP line replies, and server-sent events.
