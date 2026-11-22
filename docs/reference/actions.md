# Action context reference

Rule blocks, `on_eof` blocks, and generated action bodies run with the lexer
instance as `self`.

## Token methods

| Method | Contract |
|---|---|
| `emit(type, value = text)` | Queue one token; `type` may be `nil` |
| `skip` | Queue no token for the current match |
| `echo` | Equivalent to `emit(nil, text)` |
| `error!(message)` | Apply the configured input error policy to a `LexError` |

## Match and position methods

| Method | Contract |
|---|---|
| `text` | Matched text, including a `more` prefix when present |
| `text_bytesize` | Byte size of `text` |
| `captures` | Frozen hash of named groups from the original rule match |
| `last_location` | A `Runtime::Location` for the current text span |
| `lineno` / `line` | One-based current line number |
| `byte_pos` | Current byte offset |
| `beginning_of_line?` | Whether the current position is at line start |
| `state` | Current state symbol |
| `binary_input` | Input as a binary string |

`text` is memoized for the current action. `last_location` uses the same span;
`more` makes the span include all joined matches.
See [named captures](regexp.md#captures) for group values and match bounds.

`push_input(input, filename: nil)` queues another source for the next token
boundary. The current action keeps its match text and location. See
[input stack](runtime.md#input-stack) for EOF and location behavior.

## Delegate a capture to another lexer

`delegate(ChildLexer, capture: :name)` scans the exact byte range of a named
capture with a new child lexer. Call it from a default-channel rule action
that has the named capture. An optional group that did not match contributes
no tokens. An empty capture is an empty child input, so its EOF action can
still emit a token.

The child starts in its initial state. Its default-channel tokens are
inserted in order before any ordinary token emitted by the parent action.
The parent keeps its lexical state and original match. If the action uses
`less`, the delegated range must fit inside the final match.
An indentation-aware parent treats the delegating rule as one content match.

Both lexers need the same encoding. A parent with `token_kind :struct`
requires a structured child. Child token locations, attached trivia, and
lexical errors use the original byte offsets and coordinates in the parent
file. The child reads only the capture. Its beginning of line and EOF
conditions are relative to that input. Attempts to switch to another input
with `push_input` raise `ArgumentError`. Parent array and yield modes return
their usual token pairs.

A child uses the parent's error mode and scan limits. Delegated work counts
toward the parent's step limit, with a maximum of 32 nested children. Custom
error handlers stay with the lexer on which they were installed. The action
receives `nil` from `delegate` after staging the child tokens.

For a small HTML lexer, use an absence group to keep the closing tag out of
the capture. Put each lexer in its own source file for generation.

```ruby
# js.flexr.rb
require "flexr" unless defined?(Flexr::Lexer)

class JsLexer < Flexr::Lexer
  token_kind :struct
  rule(/[a-z_][a-z_0-9]*/, emit: :JS_IDENT)
  rule(/[ \t\r\n]+/, channel: :space, emit: :SPACE)
end
```

```ruby
# html.flexr.rb
require "flexr"
require_relative "js"

class HtmlLexer < Flexr::Lexer
  token_kind :struct
  rule(%r{<script>(?<js>(?~</script>))</script>}) { delegate JsLexer, capture: :js }
  rule(/[^<]+/, emit: :HTML_TEXT)
end
```

Generate `js.rb` as a regular compiled artifact and `html.rb` in either
generated mode. For standalone HTML, the child shares its embedded runtime.
The child must use features available in that runtime. Add
`option :delegation` if the call to `delegate` happens in a helper outside
the lexer source.

## State methods

| Method | Contract |
|---|---|
| `push(name)` / `push_state(name)` | Save the current state and enter `name` |
| `pop` / `pop_state` | Restore the previous state, or `:initial` when the stack is empty |
| `begin_state(name)` / `state=` | Enter `name` without changing the stack |

## Flex-compatible methods

| Method | Contract |
|---|---|
| `less(count)` | Keep only the first `count` bytes of the current match |
| `more` | Join the next match into the current token text |

`less` cannot exceed the current matched byte count. In UTF-8 mode its result
must also be a codepoint boundary. Returning to the same byte and state is a
non-progress error; state-changing rescan cycles are detected as well. `more`
is finalized after the action; call `emit` only after the complete text has
been assembled.
