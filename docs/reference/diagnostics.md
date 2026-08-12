# Diagnostics catalog

Diagnostics have a code, severity, message, optional location, help, and note.
Use `flexr check SPEC --format json` to consume the structured form.

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
