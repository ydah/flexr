# Public API and stability

Compatibility guarantees apply only to the stable surface below. Everything
else may change between releases without a deprecation cycle.

## Public and stable

- `Flexr::Lexer` and the DSL methods in [dsl.md](dsl.md).
- `Flexr::Pattern` values and the [pattern algebra](dsl.md#patternvalues).
- Runtime consumption: `initialize`, `next_token`, `tokens`, `each_token`, and
  `racc_next_token`.
- `Flexr::Lexer.recognizer` and `Flexr::Recognizer#match` for
  [action-free matching](runtime.md#action-free-recognition).
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
## Type signatures

The gem includes RBS signatures in `sig/flexr.rbs` for the stable API above.
Steep can discover them through an application's RBS collection or an explicit
`library "flexr"` entry. User-defined token values and internal regexp ASTs
remain `untyped`; the signatures do not make internal tables stable APIs.
Token and location records inherit from `Data`; fields are read-only and `with`
returns a replacement. Their fields are nullable because their public constructors
allow omitted keywords. The token representation remains a union of arrays and
structured tokens because `token_kind` is selected dynamically.
Cancellation signatures accept Procs, Methods, and callable objects taking zero
arguments or the lexer. `on_error=` accepts a callable returning `:skip`,
`:raise`, `:token`, or `:halt`; assigning nil clears the handler.

Validate the signatures and type-check the consumer example with:

```sh
BUNDLE_GEMFILE=gemfiles/types.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/types.gemfile bundle exec rbs -I sig validate
BUNDLE_GEMFILE=gemfiles/types.gemfile bundle exec steep check
```

The type-checking tools run in a separate CI matrix for Ruby 3.4 and 4.0,
matching the runtime's supported Ruby versions. They add no runtime dependency to flexr.
This checks the public signatures and a typed consumer, not the entire internal
implementation.

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
