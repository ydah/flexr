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
