# Replay for named regexp captures

The capture contract is in [20261122_named_captures_of_selected_rule.md / Decision](../adr/20261122_named_captures_of_selected_rule.md#%E6%B1%BA%E5%AE%9A).

DFA compilation treats named groups as transparent and remembers the pattern index of the winning acceptance.
`Automaton::Compiler#prepare_capture_pattern` creates a Ruby regexp with absolute anchors and the same encoding and character classes as the DFA.
`Runtime::Captures` runs the anchored regexp on the matched body only when an action requests capture data.
The native `firstmatch` scanner can supply its existing `MatchData` instead.
Captures from an earlier action are cleared after that action completes.

Generated artifacts store replay expressions only for rules with named groups.
An artifact with capture metadata checks runtime support when it loads.

The [tagged capture experiment](../perf-log.md#tagged-captures) records the bounded alternative to replay and the cases that would need verification before adopting it.
