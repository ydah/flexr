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

## Import failures

`flexr import` reports untranslated actions as `FLEXR-TODO`, returns status 1,
and never writes incomplete output. This is intentionally stricter than a
best-effort migration because a partially translated lexer can silently change
language behavior.
