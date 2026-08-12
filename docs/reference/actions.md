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
| `last_location` | A `Runtime::Location` for the current text span |
| `lineno` / `line` | One-based current line number |
| `byte_pos` | Current byte offset |
| `beginning_of_line?` | Whether the current position is at line start |
| `state` | Current state symbol |
| `binary_input` | Input as a binary string |

`text` is memoized for the current action. `last_location` uses the same span;
`more` makes the span include all joined matches.

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
