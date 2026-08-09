# Reference

## DSL

- `rule(pattern, skip: true, emit: :TOKEN, followed_by: regexp)` registers a
  longest-match rule. `Regexp`, `String`, and arrays of either are accepted.
- `state(:name, inclusive: false) { ... }` creates an exclusive or inclusive
  start condition. Actions can call `push`, `pop`, and `begin_state`.
- `emits :TOKEN` documents token names and lets `check` diagnose undeclared
  emissions. `token_kind` accepts `:array`, `:struct`, and `:yield`.
- `on_eof { ... }` installs a state-specific EOF action.

## CLI

```sh
flexr check lexer.flexr.rb
flexr stats lexer.flexr.rb --format json
flexr dot lexer.flexr.rb > lexer.dot
flexr trace lexer.flexr.rb
flexr lexer.flexr.rb -o lexer.rb
```

`--eval` executes trusted specification code when static evaluation cannot
resolve a pattern. Never run it on an untrusted file.

## Supported regular expressions

The DFA subset includes literals, alternation, grouping, character classes,
Unicode properties, anchors at the pattern edges, and greedy `*`, `+`, `?`, and
`{n,m}`. Lookaround, backreferences, lazy/possessive quantifiers, `\b`, and
conditional expressions are rejected with `FLEXR-E014`; use `followed_by:` or a
state transition as the replacement.
