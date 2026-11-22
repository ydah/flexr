# Matching semantics

flexr ranks candidates at the current position by their total matched byte
length, including any `followed_by:` context. When lengths tie, the highest
`priority:` wins. Equal priorities use source order. The scanner consumes
only the winning rule body.

This is why `==` beats `=` when both rules have no trailing context,
regardless of which rule is written first.

The matcher is byte-oriented so binary input and invalid UTF-8 have deterministic
behavior. UTF-8 patterns still require valid codepoint boundaries before a
match is accepted. Unicode properties and POSIX classes are expanded from the
vendored UCD into this same model rather than matched by a separate host-regexp
path. The runtime and generated scanner share the compiled model; acceleration
may skip self-loop bytes but cannot change the winner.

Use `backend :firstmatch` for specifications that depend on source order.
It selects the first matching rule and preserves Ruby regexp alternative order
within that rule. See the [first-match compatibility record](../adr/20261122_stable_explicit_firstmatch.md#%E6%B1%BA%E5%AE%9A).
