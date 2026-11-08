# Diagnostics catalog

Diagnostics have a code, severity, message, optional location, help, and note.
Use `flexr check SPEC --format json` to consume the structured form.

## Source context in human output

When a diagnostic has a source range, human output includes the file, line,
column, source line, and carets. For example, given `lexer.flexr.rb`:

```ruby
class Lexer < Flexr::Lexer
  rule(/[a-z]+/, skip: true)
  rule(/if/, skip: true)
end
```

`flexr check lexer.flexr.rb --color never` prints:

```text
warning[FLEXR-W001]: rule /if/ is unreachable (shadowed by rule /[a-z]+/)
  --> lexer.flexr.rb:3:3
  |
3 |   rule(/if/, skip: true)
  |   ^^^^^^^^^^^^^^^^^^^^^^
  help: remove it, reorder the rules, or make its language distinct
  note: example: "if" selects rule /[a-z]+/ (same length, earlier rule wins)
```

Line and column numbers are one-based. Columns count characters rather than
UTF-8 bytes. A multiline range shows its first source line; an empty range
gets one caret. Tabs are preserved, but wide or combining characters can make
caret alignment differ from terminal display widths.

Source ranges are available for:

- Ruby syntax errors (`FLEXR-E010`).
- Static DSL errors: unsupported encoding (`FLEXR-E011`), `reject` actions
  (`FLEXR-E013`), unresolved expressions or unsupported DSL structure
  (`FLEXR-E017`), and invalid pattern or trailing-context types (`FLEXR-E018`).
- Rule compilation errors, including empty matches (`FLEXR-E005`), repetition
  limits (`FLEXR-E007`), misplaced anchors (`FLEXR-E009`), and unsupported regexp
  constructs (`FLEXR-E014`), including errors in trailing context.
- Rule warnings: `FLEXR-W001`, `FLEXR-W003`, `FLEXR-W010`, `FLEXR-W012`,
  `FLEXR-W013`, and `FLEXR-W014`.
- State and specification diagnostics: DFA state limits (`FLEXR-E006`), empty
  states (`FLEXR-W002`), large transition tables (`FLEXR-W011`), and slow DFA
  construction (`FLEXR-W016`).

Rule diagnostics highlight the complete rule declaration. `FLEXR-W010` points
to the later rule in the reported pair. `FLEXR-W014` points to the first rule
emitting the undeclared token, with one warning per token.

Compiler diagnostics identify rules by their patterns rather than numeric
indices. Regexp options, quoted strings, arrays of patterns, and `followed_by:`
context are preserved in these labels. For longest-match specifications without
trailing context, `FLEXR-W001` also names the patterns that shadow the unreachable
rule; otherwise, its example identifies the verified winner. `FLEXR-E006` lists
the patterns in the state being compiled. String trailing context is shown as
its compiled literal regexp. These labels also appear in JSON messages and when
source ranges are unavailable.

`FLEXR-W001` notes include a shortest nonempty input, measured in bytes, and
the rule selected for that input. Examples for named lexical states
include the state name. Control characters and binary bytes are escaped, and
the same note is preserved in JSON and generated artifacts.

For `firstmatch`, the candidate is checked with the scanner's regexp matcher
without running actions. The note identifies the first rule selected and its
matched byte count, which can be shorter than the example input. For example,
`"ab"` can select an earlier `/a/` rule with a one-byte match.

For states using `followed_by:`, the candidate includes the shortest trailing
input and is checked using the active rules. Longest-match backends compare
the combined body and lookahead length; `firstmatch` keeps rule-order priority.
The note separates consumed bytes from lookahead bytes. For example, two rules
with body `/a/` and trailing context `/b+/` produce this note with backend `table`:

```text
example: "ab" selects rule /a/, followed_by: /b+/ (longest total match, then rule order; matched 1 byte, looked ahead 1 byte)
```

If a checked candidate selects the supposedly unreachable rule in any lexical
state, W001 is omitted for that rule. No rule actions run during these checks.
An example is omitted when the candidate is empty, invalid in the specification's
encoding, or cannot be confirmed by the matcher. This includes trailing patterns
that the runtime cannot compile. Candidate generation does not search for an
alternative if anchor or encoding checks reject the shortest candidate.

Static DSL errors highlight the offending DSL call. Unresolved expressions
point to the expression instead; ambiguous lexer selection points to the
second lexer class containing DSL calls.

State diagnostics point to the first declaration of the affected state.
`FLEXR-E006` identifies the state being compiled, while `FLEXR-W011` identifies
the state with the largest transition table. The implicit `initial` state
and the total construction time (`FLEXR-W016`) point to the lexer class.

Rules and states created directly through the runtime DSL do not carry source
ranges. Diagnostics without ranges, or whose source cannot be read, retain
the message, help, and note without a source excerpt.

For direct rendering, pass the matching source text and optional file path to
`DiagnosticSet#render(source: source, path: path)`. Without a path, the label is
`(source)`. JSON output keeps `location` as a pair of byte offsets with an
exclusive end; source excerpts are not added to JSON.

Runtime input diagnostics (`FLEXR-E003`, `FLEXR-E012`, `FLEXR-E013`,
and `FLEXR-E021` through `FLEXR-E027`)
use `[byte_pos, byte_pos]` to mark their reported position in the original
input. Guard notes identify the affected rule by its pattern when available,
using the same labels as compiler diagnostics. Pass the complete input to
`DiagnosticSet#render` to show its line and caret; see
[errors and recovery](errors.md). These offsets remain absolute
when a streaming buffer discards consumed input. If the CLI reports a runtime
input failure, it reads the error's `filename` for context, preserving the
input's original line endings. To bound memory use while reporting input
failures, the CLI omits excerpts for input files larger than 64 KiB. An absent
or unreadable input file also produces the diagnostic without an excerpt.

## Errors

| Code | Meaning | First fix to try |
|---|---|---|
| `FLEXR-E001` | Regexp syntax is malformed | Correct the regexp syntax |
| `FLEXR-E003` | A state name is undefined | Declare the state before entering it |
| `FLEXR-E005` | A rule can match an empty string | Make it consuming or opt into `allow_empty_match` |
| `FLEXR-E006` | DFA state limit exceeded | Raise `max_dfa_states` or split rules |
| `FLEXR-E007` | Bounded repetition exceeds 1000 | Use a smaller bound or split the rule |
| `FLEXR-E009` | Anchor is not at an outermost boundary | Move `^` / `$` or split alternatives |
| `FLEXR-E010` | Prism reported source syntax errors | Fix Ruby syntax in the specification |
| `FLEXR-E011` | Encoding is not UTF-8 or binary | Change `encoding` |
| `FLEXR-E012` | Runtime token exceeded the size limit | Raise `max_token_size` or split the token |
| `FLEXR-E013` | `reject` is not supported | Use states and `less` |
| `FLEXR-E014` | Regexp construct is not DFA-compatible | Follow the diagnostic alternative |
| `FLEXR-E017` | Pattern is not statically resolvable | Rewrite as a static expression or use trusted `--eval` |
| `FLEXR-E018` | Rule pattern or trailing context has an invalid type | Use a regexp, string, or valid array |
| `FLEXR-E019` | Prism is unavailable for generation | Install the generator dependencies |
| `FLEXR-E020` | Generated artifact metadata is missing or incompatible | Regenerate with the installed flexr version |
| `FLEXR-E021` | An action or state cycle made no input progress | Consume input or break the state cycle |
| `FLEXR-E022` | The retained streaming buffer is too large | Shorten tokens, raise the limit, or disable retention |
| `FLEXR-E023` | Runtime work exceeded `max_steps` | Raise the limit or simplify the specification |
| `FLEXR-E024` | Trailing context exceeded its lookahead limit | Bound the context or raise the limit |
| `FLEXR-E025` | The lexical state stack overflowed | Remove recursive pushes or raise the limit |
| `FLEXR-E026` | A cancellation callback stopped lexing | Resume with a new lexer when ready |
| `FLEXR-E027` | An error callback returned an unknown action | Return `:skip`, `:raise`, `:token`, or `:halt` |

## Warnings

| Code | Meaning | First fix to try |
|---|---|---|
| `FLEXR-W001` | Rule is unreachable or shadowed | Remove, reorder, or distinguish it |
| `FLEXR-W002` | Named state has no rules | Add rules or remove the state |
| `FLEXR-W003` | Trailing context has variable length | Make both parts fixed length |
| `FLEXR-W010` | `firstmatch` overlap may change semantics | Use the stable table backend |
| `FLEXR-W011` | Transition table is large | Use direct backend, compression, or split rules |
| `FLEXR-W012` | Trailing context cannot use region acceleration | Remove context or set `accel :none` |
| `FLEXR-W013` | Capturing group is treated as non-capturing | Use `(?:...)` |
| `FLEXR-W014` | Emitted token is not declared | Add it to `emits` or accept the warning |
| `FLEXR-W016` | DFA construction took more than 0.5 seconds | Use generated mode for startup |

Warnings are reported by `check` according to `--warn`. The default omits the
wall-clock `FLEXR-W016`; `--warn all` includes it, and `--warn none` suppresses
warnings. `--warn-as-error` turns selected warnings into a failed command.
