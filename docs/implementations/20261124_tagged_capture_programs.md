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
