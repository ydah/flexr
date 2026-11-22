# DSL reference

The DSL is extended onto a subclass of `Flexr::Lexer`. Class bodies are normal
Ruby and may contain constants, methods, requires, comments, and ordinary
expressions.

## `rule(pattern, skip: false, emit: nil, followed_by: nil, channel: :default, priority: 0, emits: nil, &action)`

Registers one rule. `pattern` is a `Regexp`, `String`, `Flexr::Pattern`, or an
array containing those values. A string is matched literally. Array members
are alternatives of one rule and share its action.

`skip: true` discards the match and takes precedence over `emit` and the block.
`emit: :TOKEN` installs a simple action that emits the token with the matched
text as its value. Without either option, the block runs in the lexer instance;
if no block is given, the default action emits `[nil, text]`.

Prefer `emit:` when the value is the unchanged matched text, such as
`rule(/\+/, emit: :PLUS)`. This avoids executing a Ruby action block for each
token. Use a block when converting a value or changing lexer state.

For parser-driven lexing, `emits:` declares which token types an action can
return. Pass one Symbol or a nonempty array of Symbols. Use `emit:` alone
when the rule already declares its token and emits the matched text. The
class-level `emits` method continues to declare the grammar's token list.
See [parser token expectations](runtime.md#parser-token-expectations).

`followed_by:` accepts a `Regexp`, `String`, or `Flexr::Pattern`. It
participates in rule selection while leaving the lookahead for the next token.
The method returns `nil`. Rules are numbered in source order starting at zero.

## `pattern(*values)`

Builds an immutable, Ractor-shareable `Flexr::Pattern` from regexps, literal
strings, existing pattern values, and arrays of those values. Multiple values
form alternatives. Assign a pattern to a constant to reuse it in other
patterns and in rules.

```ruby
class Words < Flexr::Lexer
  IDENT = pattern(/[a-z_][a-z0-9_]*/)
  KEYWORD = pattern(%w[if else end while])
  SHORT = pattern(/.{1,8}/)

  rule(KEYWORD, emit: :KEYWORD)
  rule((IDENT & SHORT) - KEYWORD, emit: :SHORT_IDENT)
  rule(!pattern(/.*__.*/) & IDENT, emit: :IDENT)
end
```

| Operator | Language |
|---|---|
| `a \| b` | Strings matched by either operand |
| `a + b` | A match of `a` followed by a match of `b` |
| `a & b` | Strings matched by both operands |
| `a - b` | Strings matched by `a` and excluded by `b` |
| `!a` | All strings in the subject alphabet outside `a` |

Complement is relative to valid Unicode scalar strings in a UTF-8 lexer and
all byte strings in a binary lexer. Use line anchors in a plain rule regexp.
Pattern operations and earlier constant definitions are resolved by the static
generator. `flexr explain` and `flexr dot` display the constant names used
in a rule.

Use `table`, `direct`, or `auto` for rule bodies built from pattern values.
All backends can use pattern values as trailing context. Runtime and generated
scanners keep the usual longest-match and rule order policies. Whole-token
acceleration is disabled in states that contain pattern values.

## `upto(terminator)`

Returns a pattern that ends at the first completed match of `terminator`,
including that match. The terminator uses the same input forms as `pattern`.
An occurrence can start anywhere in the span, and an absent terminator gives
no match. If the terminator can match the empty string, its first occurrence
ends immediately. A whole rule that can match without consuming input
reports `FLEXR-E005` unless empty matches are enabled.

```ruby
rule(pattern("/*") + upto("*/"), skip: true)
```

For an overlapping terminator such as `"aba"`, `upto("aba")` consumes
three bytes from `"ababa"`. Further rules can consume the remaining text.

See [pattern diagnostics](diagnostics.md#pattern-operations) and
[ADR 0029](../adr/0029-pattern-algebra.md).

`channel:` accepts a symbol. The default is `:default`; other named
channels preserve tokens as trivia for `tokens(channels: :all)`.
`channel: :skip` is equivalent to `skip: true`, which discards the match
in every consumer. `:all` selects channels when collecting tokens.
With a trivia channel and no explicit action or `emit:`, the channel name
becomes the token type and the matched text becomes the value.
Static generation requires a symbol literal or a statically resolvable
symbol constant for the channel name. With `--eval`, a Ruby expression can
compute that symbol.

`priority:` accepts an integer and defaults to zero. On longest-match
backends, the highest priority wins among rules with the same total match
length, including any trailing context. Source order breaks ties between
equal priorities. For example, a later `rule("if", emit: :IF, priority: 10)`
can win over an identifier rule on `if`, while the identifier rule still
wins on `ifx`.

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

Declares default-channel token names for diagnostics and parser integration. Arguments are
flattened and converted to symbols. Duplicate names are removed. The method
does not restrict `emit` at runtime.

## `keywords(words, among:)`

Remaps the token type of a winning default-channel rule declared with
`emit: :TOKEN`. Pass the base type as `among:` and a nonempty array of exact
UTF-8 spellings.
Each spelling maps to its uppercase symbol. Use a hash of strings to symbols
to choose names or assign the same type to several spellings.

```ruby
rule(/[a-z_][a-z0-9_]*/, emit: :IDENT)
keywords %w[if else end], among: :IDENT
keywords({ "yes" => :TRUE, "true" => :TRUE }, among: :IDENT)
```

`if` produces `[:IF, "if"]` and `ifx` produces `[:IDENT, "ifx"]`.
The lookup is case-sensitive and runs after rule selection. Token text and
locations stay the same, including text accumulated by `more`. The lookup
uses the winning rule's own lexeme. Action blocks keep control of their
emitted types. The table applies to matching default-channel `emit:` rules
across lexical states. Trivia rules can still win under normal rule selection.

The base and mapped types are added to `emits` and checked by
`check --grammar`. Multiple declarations can extend a table. A spelling
may have only one mapped type within that table. Every spelling must
match the full body of a default-channel rule with the base type, or compilation reports
`FLEXR-E028`. A competing rule may win on the same spelling by priority or
source order. The compiler reports `FLEXR-W022` when the DFA can prove
that the spelling always reaches the competing rule.
See [ADR 0030](../adr/0030-classify-keywords-after-matching.md) for the decision
to keep keyword spellings out of the DFA.

## `indentation(newline:, indent:, dedent:, brackets: [], tab_width: 8)`

Configure layout processing with three distinct token Symbols. Emit the
configured `newline` for LF or CRLF. A newline rule may also consume the
following spaces and tabs. Skip ordinary whitespace and comments, or send
them to trivia channels. Keep each layout-significant line break visible as
the configured newline token.

`brackets` contains two-character strings, each with an opening and a
closing character. Each character can appear in one pair. A recognized
bracket token is identified by its original matched character. Set
`tab_width` to a positive integer. A tab advances to the next tab stop.

See [indentation tokens](runtime.md#indentation-tokens) for the output order
and positions.

## `backend(name)`

Selects `:table`, `:direct`, `:auto`, or `:firstmatch`
backend. `:table`, `:direct`, and `:auto` preserve the stable longest-match
contract. `:firstmatch` selects the first matching rule in source order,
even when a later rule could consume more text. Within a rule, alternation
also follows Ruby regexp order. Choose it when rule priority is intentional;
the compiler reports possible differences from longest-match as `FLEXR-W010`.
The default remains `:table`.

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
`:unicode`, `:eager_columns`, and `:allow_empty_match`. `:experimental` remains
accepted for compatibility; it is no longer required by `:firstmatch`.
`:standalone` is build metadata used by standalone generation. `:input_stack`
includes support for external callers of `push_input` in a standalone lexer.
`:delegation` adds the [delegation helper](actions.md#delegate-a-capture-to-another-lexer)
for indirect calls. Unknown option names raise immediately so misspellings cannot silently change
behavior.

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
