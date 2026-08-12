# DSL reference

The DSL is extended onto a subclass of `Flexr::Lexer`. Class bodies are normal
Ruby and may contain constants, methods, requires, comments, and ordinary
expressions.

## `rule(pattern, skip: false, emit: nil, followed_by: nil, &action)`

Registers one rule. `pattern` is a `Regexp`, `String`, or an array containing
those values. A string is matched literally. Array members are alternatives of
one rule and share its action.

`skip: true` discards the match and takes precedence over `emit` and the block.
`emit: :TOKEN` installs a simple action that emits the token with the matched
text as its value. Without either option, the block runs in the lexer instance;
if no block is given, the default action emits `[nil, text]`.

`followed_by:` accepts a `Regexp` or `String`. It participates in rule
selection but is not consumed. The method returns `nil`. Rules are numbered in
source order starting at zero.

## `state(*names, inclusive: false, &block)`

Creates one or more named states and registers rules in the block for those
states. The block is required. Named states are exclusive by default. An
inclusive state also sees rules registered for `:initial`.

Nested state blocks register their rules for every enclosing state, matching
Ruby runtime evaluation. Repeating a state declaration with a different
`inclusive:` value raises immediately instead of silently retaining or replacing
one declaration.

## `all_states(&block)`

Registers the block for every state known when the call is evaluated, including
`:initial`. It has the same rule-registration behavior as `state`.

## `on_eof(&action)`

Installs an action for EOF in the current state. If called outside a state block,
the action belongs to `:initial`. The action can emit a final token, change
state, or do nothing. It runs at most once per state for a lexer instance.

## `emits(*tokens)`

Declares token names for diagnostics and parser integration. Arguments are
flattened and converted to symbols. Duplicate names are removed. The method
does not restrict `emit` at runtime.

## `backend(name)`

Selects `:table`, `:direct`, `:auto`, or the experimental `:firstmatch`
backend. `:table`, `:direct`, and `:auto` preserve the stable longest-match
contract. `:firstmatch` requires `option :experimental` and can change the
meaning of overlapping rules.

## `token_kind(name)`

Selects `:array`, `:struct`, or `:yield`. The default is `:array`. See the
[token contract](tokens-and-locations.md) for the exact shapes.

## `encoding(value)`

Accepts `Encoding::UTF_8`, `Encoding::BINARY`, or a name resolving to one of
them. Other encodings raise `FLEXR-E011`. The regexp encoding can override the
specification encoding for an individual pattern only when the resulting byte
model is valid.

## `option(*values)`

Adds boolean options to the specification. Stable options include
`:unicode`, `:eager_columns`, and `:allow_empty_match`. `:experimental` is a
capability opt-in for experimental behavior such as `:firstmatch`.
`:standalone` is build metadata used by standalone generation. Unknown option
names raise immediately so misspellings cannot silently change behavior.

## `accel(value)`

Selects `:auto`, `:strscan`, `:regexp`, or `:none` for runtime region
acceleration. Acceleration is an optimization; the DFA remains the semantic
source of truth. Affected trailing-context rules cannot use region acceleration.

## Compilation helpers

`compile!` and `dfa` exist for diagnostics and integration internals. The first
compilation makes the specification immutable; later calls to `rule`, `state`,
`backend`, `option`, and other declaration methods raise
`Flexr::FrozenSpecificationError`. This keeps the compiled DFA and its DSL
definition from diverging. These helpers are not required for normal use and
are not compatibility-stable; use the lexer constructor and token methods
instead. See [public API](public-api.md).

Subclassing a custom lexer class starts a new, empty specification; rules and
states are not inherited. This avoids silently changing rule order or state
membership in the child class.
