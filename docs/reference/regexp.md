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
| `\b`, `\B` | Unsupported | Use the literal-boundary examples in `FLEXR-E014` where applicable; token edges need rules or state checks |
| `\A`, `\z`, `\Z` | Unsupported | The `^` / `$` examples in `FLEXR-E014` apply only to input without line feeds |
| `\G` | Unsupported | At the start of a rule, omit it: rules already match at the current lexer position |
| `\K` | Unsupported | Use the prefix/suffix state example in `FLEXR-E014` where applicable to preserve token text and location |
| Subexpression calls `\g<...>` | Unsupported | Inline non-recursive expressions; recursive calls need a parser or state stack |
| `\X` | Unsupported | Use the ASCII-only standalone token example in `FLEXR-E014` where applicable; Unicode graphemes need separate segmentation |
| Lazy or possessive quantifiers | Unsupported | For unescaped single-line quoted text, use `/"[^"\n]*"/`; other patterns need a separate rewrite |
| Atomic groups | Unsupported | Use the delimited-text example in `FLEXR-E014` where applicable; removing atomic groups can change matches |
| Named groups `(?<name>...)` and `(?'name'...)` | Supported | Read values from `captures` in rule actions |
| Conditional groups | Unsupported | Use the finite alternatives shown by `FLEXR-E014` where applicable, or separate rules and state checks |
| Absence groups `(?~X)` | Supported | Rule patterns require a longest-match backend. See [absence groups](#absence-groups) |

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

## Absence groups

`(?~X)` matches text containing no substring matched by `X`. The group
can consume line feeds. In UTF-8 it consumes complete Unicode scalars, and
in binary mode it consumes bytes. For example, this rule skips C-style
comments through the first closing delimiter.

```ruby
rule(%r{/\*(?~\*/)\*/}, skip: true)
```

Each occurrence of the forbidden expression must fit within the group's
own span. The normal longest-match rule still applies to the surrounding
pattern, including delimiters that can overlap themselves.

If `X` can match the empty string, the group has an empty language because
every string contains the empty string. Otherwise the group can itself
match empty input, so a rule consisting of `(?~X)` alone reports
`FLEXR-E005` unless empty matches are enabled.

The compiled automaton uses this language definition in runtime, generated,
and standalone modes. Ruby 4.0.9's regexp matcher, for example, accepts
empty input for `\A(?~a?)\z`; flexr's `(?~a?)` has an empty language.
Likewise, flexr parses `X` as an ordinary alternation in `(?~a|b)`.

Use `table`, `direct`, or `auto` for rule patterns that use absence.
All backends support non-nullable absence expressions in `followed_by:`
because trailing context is evaluated by a DFA. Extended `(?~|...)`
forms report `FLEXR-E014`. Anchors inside `X` report `FLEXR-E009`.

See the [absence implementation record](../implementations/20261122_dfa_absence_groups.md) for the compilation strategy.

## Captures

A rule action can read named groups from the winning regexp.

```ruby
rule(/(?<integer>[0-9]+)\.(?<fraction>[0-9]+)/) do
  emit :DECIMAL, [captures[:integer], captures[:fraction]]
end
```

`captures` returns a frozen hash with symbol keys and frozen string values.
An optional group that did not participate has the value `nil`.
Actions for other patterns and EOF receive an empty hash.

Longest-match backends select the rule and its body before Ruby's regexp
engine resolves the groups within that body. Ambiguous groups follow
Ruby's capture rules. `firstmatch` uses the captures from its selected native
match. If two patterns of the same rule accept the winning body, the first
eligible pattern supplies the captures.

The body excludes `followed_by:` and any prefix accumulated by `more`.
Calling `less` changes the token text and position while captures still
describe the original body. Groups in pattern algebra and trailing context
affect matching and produce no entries in `captures`.

Unnamed groups are treated as grouping syntax and produce `FLEXR-W013`.
Backreferences and calls to capture groups still report `FLEXR-E014`.
See the [capture replay implementation record](../implementations/20261122_replay_named_regexp_captures.md) for the extraction strategy.
