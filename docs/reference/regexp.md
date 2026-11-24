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
| `^` | Restricted | Allowed at the start of the outermost rule pattern; otherwise `FLEXR-E009` |
| `$`, `\z`, `\Z` | Supported | See [end anchors](#end-anchors) |
| `/i`, `/m`, `/x`, `/n` | Supported | Inline forms are supported where Ruby permits them |
| `\d`, `\w`, `\s` | Supported | Unicode-aware with `option :unicode` in UTF-8 |
| `\h`, `\H` | Supported | Hexadecimal digits and their complement |
| Octal escapes such as `\011` | Supported | Match bytes in binary mode and complete encoded characters in UTF-8 |
| `\R` | Supported | Recognizes CRLF as one atomic line break |
| Positive `(?=...)` and negative `(?!...)` lookahead | Supported | See [lookahead](#lookahead) |
| Positive and negative lookbehind | Unsupported | Track preceding input with rules or states |
| Backreferences | Unsupported | Enumerate finite repeated strings, or use states and action checks |
| `\b`, `\B` | Unsupported | Use the literal-boundary examples in `FLEXR-E014` where applicable; token edges need rules or state checks |
| `\A` | Unsupported | The `^` example in `FLEXR-E014` applies to input without line feeds |
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

## Octal byte escapes

`\011` and `\x09` both match a tab. An octal escape consumes up to three
octal digits. Begin with `\0` for an unambiguous escape outside a character
class when the value fits in that form. Ruby interprets decimal forms such as
`\1` and `\10` as backreferences when they refer to captures, and flexr
reports `FLEXR-E014` for those references.

In UTF-8, consecutive escaped bytes can form a multibyte character. For
example, `\303\251` and `\303\xA9` both match `é`. In binary mode, `\377`
matches the byte `0xff`.
[Ruby's regexp escape syntax](https://docs.ruby-lang.org/ja/4.0/doc/spec=2fregexp.html)

## Line breaks

`\R` matches CRLF, CR, LF, vertical tab, or form feed. In UTF-8 it also
matches U+0085, U+2028, and U+2029. CRLF is atomic. For example, `/\R\n/`
accepts CRLF followed by an additional LF. A CR followed by LF belongs to
the pair even when the LF falls beyond the end of a candidate token.
See [Ruby's line break syntax](https://docs.ruby-lang.org/en/4.0/Regexp.html#class-Regexp-label-Shorthand+Character+Classes).

## End anchors

| Anchor | Positions where it matches |
|---|---|
| `$` | Before any LF or at the end of the active input source |
| `\z` | At the end of the active input source |
| `\Z` | Immediately before a final LF or at the end of the active input source |

End anchors consume zero bytes. For example, `/a$\nb/` consumes `a\nb`
when the line ends after `a`. On `a\nb`, `/a\Z/` fails because the
LF is followed by `b`. On `a\r\n`, `/a\r\Z/` matches through the CR.

A streamed lexer checks the following bytes before deciding whether it has
reached a line or source end. An included input has its own source end.
The end of a loaded chunk or a candidate token has no effect on the
assertion. Malformed UTF-8 still occupies bytes in the active source.
See [Ruby regexp anchors](https://docs.ruby-lang.org/en/4.0/Regexp.html#class-Regexp-label-Anchors).

## Lookahead

A positive lookahead succeeds when its expression matches a prefix of the
remaining input. A negative lookahead succeeds when no such prefix matches.
Both assertions leave the lexer position unchanged. They can appear inside a
pattern or at its end, and they can inspect bytes beyond the token in the
active input source.

```ruby
rule(/-(?!\d)/, emit: :MINUS)
rule(/-\d+/, emit: :SIGNED_NUMBER)
rule(/a(?=bc)b/, emit: :PREFIX)
```

On `abc`, the last rule consumes `ab` and leaves `c` for the next token.
Longest-match ranking counts the bytes matched by the regexp body.
Rules using `followed_by:` keep their ranking by the combined body and
trailing match lengths. The `firstmatch` backend preserves Ruby's choice of
alternatives. Flexr's vendored case folding applies to these expressions.
For example, Ruby 4.0.9 can match `SS` with `/(?i:ß)(?=a)/u` on `SSa`.
Flexr's case folding for this expression matches the single-character
forms `ß` and `ẞ`. A named group in a successful positive assertion can capture
text beyond the token. A lookahead can read across chunks up to the
`max_lookahead_size` limit.

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

If `X` matches the empty string at every position, the group has an empty
language because every string contains the empty string. When `X` has a
zero-width assertion, its result depends on the input at the position.
A rule consisting of `(?~X)` alone reports `FLEXR-E005` if the group can
match without consuming input and empty matches are disabled.

The compiled automaton uses this language definition in runtime, generated,
and standalone modes. Ruby 4.0.9's regexp matcher, for example, accepts
empty input for `\A(?~a?)\z`; flexr's `(?~a?)` has an empty language.
Likewise, flexr parses `X` as an ordinary alternation in `(?~a|b)`.

Use `table`, `direct`, or `auto` for rule patterns that use absence.
All backends support non-nullable absence expressions in `followed_by:`
because trailing context is evaluated by a DFA. Extended `(?~|...)`
forms report `FLEXR-E014`. Use end anchors in `X` to constrain its
right context. A beginning-of-line anchor in `X` reports `FLEXR-E009`.

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
