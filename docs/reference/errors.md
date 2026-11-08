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
