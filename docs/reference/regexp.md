# Regexp compatibility

flexr accepts the regular-expression subset that can be represented by its
byte-oriented automaton. All matches start at the current lexer position.

| Ruby construct | Status | Notes and alternative |
|---|---|---|
| Literals, concatenation, alternation | Supported | |
| Groups and `(?:...)` | Supported | Captures are treated as non-capturing and warn |
| Character classes and ranges | Supported | Includes trailing `-`, POSIX classes, and `&&` intersection |
| Unicode `\p{...}` / `\P{...}` | Supported | Uses the vendored UCD snapshot |
| `*`, `+`, `?` | Supported | Greedy forms only |
| `{n}`, `{n,m}`, `{n,}` | Supported | Explicit bounds may not exceed 1000 |
| `^` / `$` | Restricted | Only at outermost pattern boundaries; otherwise `FLEXR-E009` |
| `/i`, `/m`, `/x`, `/n` | Supported | Inline forms are supported where Ruby permits them |
| `\d`, `\w`, `\s` | Supported | Unicode-aware with `option :unicode` in UTF-8 |
| `\h`, `\H` | Supported | Hexadecimal digits and their complement |
| Lookahead / lookbehind | Unsupported | Use `followed_by:` or a state; `FLEXR-E014` |
| Backreferences | Unsupported | Split the language into states or actions |
| `\b`, `\B`, `\A`, `\z`, `\G`, `\K` | Unsupported | Use rule boundaries or state/action logic |
| Lazy or possessive quantifiers | Unsupported | Use a negated character class or separate rule |
| Conditional, atomic, and capture-dependent groups | Unsupported | Rewrite as DFA-compatible rules |

Malformed syntax produces `FLEXR-E001`. Unsupported constructs produce
`FLEXR-E014`; the diagnostic help normally names the supported replacement.
Unknown alphabetic escapes are rejected rather than silently treated as
literals; escaped regexp punctuation remains supported.
Empty matches are rejected with `FLEXR-E005` unless `option :allow_empty_match`
is explicitly enabled, in which case flexr advances to guarantee progress.

## Bounded repetition

Repetition remains a symbolic AST node until NFA construction, avoiding large
intermediate trees. In `{n,m}`, `m` must be at least `n`; explicit bounds may
not exceed 1000. `{n,}` uses an unbounded loop after the required copies.

## Captures

Capturing parentheses do not expose match groups to actions. They are treated
as grouping syntax and produce `FLEXR-W013`; use `(?:...)` and inspect `text`
in the action instead.
