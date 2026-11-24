# Tagged DFA programs for named captures

The recognition DFA can accept the same token body through capture paths
with different subgroup boundaries. For example, swapping the alternatives in
`(?<head>a|aa)(?<tail>a+)` changes the capture split on `aaa`. The public
contract defines the selected token body and Ruby's subgroup precedence.
[Named capture ADR](../adr/20261122_named_captures_of_selected_rule.md#decision)

The tagged compiler records group boundaries on ordered epsilon paths. The
deterministic program delays a write until the following byte selects a
surviving path. At an accepting endpoint it applies the remaining writes to
the chosen path. Register transfers copy from the previous state before
writing the next state. A cursor can take a capture snapshot at a provisional
endpoint and continue scanning.
[A closer look at TDFA](https://arxiv.org/abs/2206.01398)

The cursor returns half-open byte ranges for the selected body. An unmatched
group has a nil range. A group that matched no bytes has an empty range.
The compiler and cursor can be tested independently of the lexer scan loop.
Ruby retains a named group's last capture when a later repetition skips it.
For duplicate names, Ruby uses the highest-numbered participating group.
The compiler also records whether a zero-byte iteration changed a capture.
Ruby uses this state when deciding whether to continue a nullable repeat
and when a group can keep a prior value.
[Ruby regexp interpreter](https://github.com/ruby/ruby/blob/master/regexec.c)

The compiler returns a program or a reason it could not construct one.
It bounds the deterministic graph, register bank, and intermediate compiler
work. Contextual assertions and nullable repetitions with larger bounds return
explicit reasons that the scanner can use to keep replay.

The compiler tests compare ranges with the anchored reference expression used
by capture replay. They cover ordered alternatives and repetitions, duplicate
names, empty and absent groups, UTF-8 and binary byte offsets, and snapshots
at successive accepting endpoints. The fixed seed covers both accepted and
rejected complete bodies.

```sh
bundle exec rspec spec/tagged_capture_programs_spec.rb
```

## Lexer scans

Runtime and generated scanners update tag registers as they consume the
recognized bytes. The winning acceptance saves its tag state with its body
end, so a speculative longer match cannot overwrite those captures. The
existing longest-match and priority rules select that endpoint. A single
group that encloses the entire pattern can use the selected body boundaries.

The lexer reads capture values lazily during the action. It retains regexp
replay for unsupported patterns, programs that exceed compiler limits, and
matched bodies changed before capture access. It also uses replay when a
cancellation callback can edit the input or a stream exposes its mutable
buffer. The boundary selected by `followed_by:` still comes from the
existing trailing-context matcher.

Generated rules store compact runs of equivalent byte classes for tagged
patterns. Standalone artifacts with those programs include the cursor and
loader. The artifact field is optional so older artifacts can use replay.

On Ruby 4.0.9 without JIT, we compared the same frozen 49,000-byte input
and verified all 7,000 tokens on each timed scan. The table gives median
milliseconds across 15 scans per side. The two versions ran in alternating
order after warmup.

| Captures read by the action | Runtime replay → tags | Generated replay → tags |
| --- | ---: | ---: |
| One group around a word | 87.33 → 89.90 | 28.58 → 30.74 |
| Separate first letter and remaining letters | 94.25 → 118.62 | 32.68 → 54.78 |

The second fixture spends more time dispatching byte steps and saving
acceptances. A separate trace counted 1,900 tagged cursor steps over 300
tokens. Regexp replay made 300 matches on the same input.
