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

## Dynamic delimiters

Call `scan_until(delimiter)` or `scan_until_line(delimiter)` from a matched
rule's action. Both start at the current `byte_pos` and return the bytes before
the first matching delimiter. A delimiter at the cursor returns an empty
string. The scan consumes the delimiter and extends the current match, so
call `emit` afterwards to give the token the full location. `text` includes
the rule's original match, the body, and the delimiter.

`scan_until` matches a literal string at byte boundaries in binary mode and
at UTF-8 scalar boundaries in UTF-8 mode. `scan_until_line` requires the
delimiter to occupy a whole line starting at the beginning of that line. It
consumes the following LF or CRLF when present and accepts a delimiter on the
last line at EOF. Line endings in the returned body are preserved.

Pass a nonempty string. UTF-8 lexers require a valid UTF-8 delimiter, and a
line delimiter may contain neither LF nor CR. A missing delimiter returns
`nil` and leaves the current match and position unchanged. A streaming buffer
can load bytes while looking for it. Token, buffer, and work limits still
apply. Call `error!` to report a missing required delimiter through the
configured error policy.

For a tagged heredoc, use a named capture from the opener to select the
closing line at run time.

```ruby
rule(/<<(?<tag>[A-Z_]+)\r?\n/) do
  body = scan_until_line(captures[:tag])
  if body
    emit :HEREDOC, body
  else
    error!("missing heredoc terminator")
  end
end
```

`less` can adjust where the scan starts or shorten its result. `more` can
carry the extended match into the next action. Standalone generation embeds
these helpers when the lexer source calls them. Add `option :dynamic_delimiters`
for indirect calls that generation cannot see.
