# ADR 0003: Leftmost-longest matching

At each input position the longest match wins. Source order breaks equal-length
ties. This is the defining semantic difference from first-match lexers.

[ADR 0032](0032-explicit-rule-priority.md) adds an explicit tie-breaker
before source order.
