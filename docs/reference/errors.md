# Errors and recovery

## Specification errors

Compile-time failures raise `Flexr::CompileError` or its
`Flexr::UnsupportedRegexpError` subclass. Both expose a structured
`diagnostic`. Static generation can additionally raise
`Flexr::StaticResolutionError` with `FLEXR-E017`.

## Input errors

`Flexr::LexError` records the message, filename, byte position, line, matched
text, and optional diagnostic. `Flexr::Runtime::TokenTooLargeError` is a
`LexError` with code `FLEXR-E012`. Other runtime guard failures use stable codes
`FLEXR-E021` through `FLEXR-E027`; see the
[diagnostics catalog](diagnostics.md). `StateStackOverflowError` is raised when
a `push` would exceed `max_state_stack`.

Undefined state transitions (`FLEXR-E003`) and `reject` calls (`FLEXR-E013`)
at runtime continue to raise `Flexr::CompileError`. These errors also expose
the input `filename` and `byte_pos`, with a diagnostic point range at the
current cursor. During a rule action this is after the matched input, unless
the action moved the cursor with `less`. EOF actions point to the end of input.
Static `reject` diagnostics still highlight the rule in the specification.

Guard diagnostics include a point range at `byte_pos` when it is known. This
is the guard's reported input position, which may be the start of a token or
the end of the loaded buffer. In a rescue handler, render it with the complete
original input:

```ruby
diagnostics = Flexr::DiagnosticSet.new << error.diagnostic
warn diagnostics.render(source: original_input, path: error.filename)
```

With `retain_input: false`, `lexer.input` contains only the retained buffer;
keep the original input separately if a source excerpt is needed. JSON
diagnostics retain absolute byte offsets even after input has been discarded.

When a guard knows the affected rule, its diagnostic note shows the pattern,
including regexp options and trailing context, for example `rule /a+/i at
byte 0`. The error's `rule` attribute still returns the numeric rule index.
Errors constructed with only a numeric index retain a numeric label; guards
without an identified rule omit the note. The diagnostic location continues
to refer to the input, not the rule declaration.

The default `error_mode: :raise` raises the lexical error. `:token` queues
`[:error, text]`; `:panic` discards the unmatched byte and continues. An
`on_error` callback can return `:skip`, `:raise`, `:token`, or `:halt` for
instance-specific control. Any other result raises
`InvalidRecoveryActionError` instead of silently applying the default policy.

### DFA continuations

When scanning fails on a byte or reaches EOF partway through a token,
`LexError#continuation` describes how the caller can complete the matched
prefix. The lexer computes it only on failure, when it raises or passes
the error to an `on_error` callback.

- `byte_pos` is the absolute byte offset after the matched prefix.
- `expected_bytes` contains inclusive byte ranges. Each byte can begin a
  suffix that lets the lexer accept a token.
- `suffix` is a shortest accepting suffix in bytes, if one exists. An empty
  string means the matched prefix accepts when the active input ends there.
- `eof` is true when the offset is at the end of the active input.

At EOF, append the suffix. At a mismatch, the suffix completes the prefix
as if the input ended after the suffix. Apply a proposed edit to your own
copy of the input and recheck it if you intend to keep later bytes.
A suffix may start in the middle of a UTF-8 character. Concatenate it to a
byte slice of the prefix before decoding the result.

The `FLEXR-E000` diagnostic marks the unexpected character or the EOF
insertion point and shows the suffix when available. An LSP server can map
`diagnostic.location` to its negotiated position encoding and use
`diagnostic.help` as the correction hint. Use a text edit only when the
edit range and replacement can be represented in the editor's encoding.
The Ruby LSP add-on analyzes lexer specifications. An input language server
can get these diagnostics by running its own lexer.

`LexError#byte_pos` and `#text` still identify the byte used by recovery.
`continuation` can be `nil` when the search reaches its work limit or the
error comes from a context without a DFA, such as a `firstmatch` scan.
The search checks UTF-8 token boundaries and declared matching conditions.
The resulting input is still subject to runtime limits and rule actions.
For a token assembled by `more`, use an EOF action to handle the case where
the last matched piece consumes the input and no new scan starts.

## Import failures

`flexr import` reports untranslated actions as `FLEXR-TODO`, returns status 1,
and never writes incomplete output. This is intentionally stricter than a
best-effort migration because a partially translated lexer can silently change
language behavior.
