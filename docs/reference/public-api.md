# Public API and stability

Compatibility guarantees apply only to the stable surface below. Everything
else may change between releases without a deprecation cycle.

## Public and stable

- `Flexr::Lexer` and the DSL methods in [dsl.md](dsl.md).
- Runtime consumption: `initialize`, `next_token`, `tokens`, `each_token`, and
  `racc_next_token`.
- Action context methods in [actions.md](actions.md).
- `Flexr::Runtime::Token`, `Flexr::Runtime::Location`, `Flexr::LexError`,
  `Flexr::CompileError`, `Flexr::UnsupportedRegexpError`, and
  `Flexr::Runtime::TokenTooLargeError`.
- `Flexr::Diagnostic`, `Flexr::DiagnosticSet`, and `Flexr::Diagnostics`.
- `Flexr::Generator` for source generation, `Flexr::RakeTask` for Rake builds,
  and `Flexr::CLI.run` for programmatic CLI invocation.
- `Flexr.compile_pattern` and `Flexr.parse_pattern` for regexp tooling.

Method arguments, return shapes, and diagnostics for this surface are described
in the reference pages and are covered by the test suite.

`require "flexr"` keeps the build tools lazy while preserving all public
constants through autoload. Applications that want an explicit load boundary
can require `flexr/runtime`, `flexr/generator`, or `flexr/cli` directly.

Runtime and generated `firstmatch` modes are stable and use the same rule-order
semantics. The former `option :experimental` opt-in remains accepted but is
unnecessary. Differences from longest-match behavior are reported as
`FLEXR-W010` rather than making generation fail.

## Experimental

Future backends or options explicitly marked experimental in their reference
may change semantics or output between minor releases.

## Internal; compatibility is not guaranteed

- `Flexr::IR`, `Flexr::Automaton`, `Flexr::Codegen`, and their members.
- `Flexr::Runtime::Buffer` and `Flexr::Runtime::Interpreter` internals.
- `Flexr::Generated` installation helpers.
- `__flexr_*` methods and instance variables.
- `Flexr::Lexer.compile!` and `.dfa` as implementation inspection hooks.

Use stable token and diagnostic APIs instead of depending on internal compiled
tables or generated installation methods.
