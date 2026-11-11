# Regexp compatibility

flexr accepts the regular-expression subset that can be represented by its
byte-oriented automaton. All matches start at the current lexer position.

| Ruby construct | Status | Notes and alternative |
|---|---|---|
| Literals, concatenation, alternation | Supported | |
| Unnamed groups and `(?:...)` | Supported | Captures are treated as non-capturing and warn |
| Character classes and ranges | Supported | Includes trailing `-`, POSIX classes, and `&&` intersection |
| Unicode `\p{...}` / `\P{...}` | Supported | Uses the vendored UCD snapshot |
| `*`, `+`, `?` | Supported | Greedy forms only |
| `{n}`, `{n,m}`, `{n,}` | Supported | Explicit bounds may not exceed 1000 |
| `^` / `$` | Restricted | Only at outermost pattern boundaries; otherwise `FLEXR-E009` |
| `/i`, `/m`, `/x`, `/n` | Supported | Inline forms are supported where Ruby permits them |
| `\d`, `\w`, `\s` | Supported | Unicode-aware with `option :unicode` in UTF-8 |
| `\h`, `\H` | Supported | Hexadecimal digits and their complement |
| Octal escapes such as `\011` | Unsupported | Use a hexadecimal escape such as `\x09` |
| `\R` | Unsupported | Use the standalone line-break rule shown by `FLEXR-E014` for the specification's encoding |
| Lookahead / lookbehind | Unsupported | Use `followed_by:` for trailing positive lookahead; other forms need rules or states; `FLEXR-E014` |
| Backreferences | Unsupported | Enumerate finite repeated strings, or use states and action checks |
| `\b`, `\B`, `\A`, `\z`, `\G`, `\K` | Unsupported | Use rule boundaries or state/action logic |
| Lazy or possessive quantifiers | Unsupported | For unescaped single-line quoted text, use `/"[^"\n]*"/`; other patterns need a separate rewrite |
| Atomic groups | Unsupported | Use the delimited-text example in `FLEXR-E014` where applicable; removing atomic groups can change matches |
| Named captures | Unsupported | Use `(?:...)` when only grouping is needed; capture-dependent patterns need a separate rewrite |
| Conditional groups | Unsupported | Use the finite alternatives shown by `FLEXR-E014` where applicable, or separate rules and state checks |
| Absence groups `(?~...)` | Unsupported | For a single excluded literal, use the negated character class shown by `FLEXR-E014`; larger expressions need a separate rewrite |

Malformed syntax produces `FLEXR-E001`. Unsupported constructs produce
`FLEXR-E014`; the diagnostic help normally names the supported replacement.
Several `FLEXR-E014` diagnostics include concrete
[rule rewrite examples](diagnostics.md#regexp-rewrite-help).
Unknown alphabetic escapes are rejected rather than silently treated as
literals; escaped regexp punctuation remains supported.
Empty matches are rejected with `FLEXR-E005` unless `option :allow_empty_match`
is explicitly enabled, in which case flexr advances to guarantee progress.

## Bounded repetition

Repetition remains a symbolic AST node until NFA construction, avoiding large
intermediate trees. In `{n,m}`, `m` must be at least `n`; explicit bounds may
not exceed 1000. `{n,}` uses an unbounded loop after the required copies.

## Captures

Unnamed capturing parentheses do not expose match groups to actions. They are treated
as grouping syntax and produce `FLEXR-W013`; use `(?:...)` and inspect `text`
in the action instead.
