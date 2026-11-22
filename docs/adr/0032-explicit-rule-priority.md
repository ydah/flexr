# ADR 0032: Break length ties with explicit rule priority

## Context

[ADR 0003](0003-leftmost-longest.md) selects the longest rule and uses source
order for ties. As specifications share rules, rewriting their declaration
order to favor a specific equal-length match can be awkward or impossible.

## Decision

In `table`, `direct` and `auto`, compare the total matched byte length first,
including trailing context. Then compare integer rule priority, highest
first, followed by source order. Rules with no explicit priority use zero.
The standalone and generated formats carry priority only for rules that use it.

`firstmatch` retains source-order matching and rejects a nonzero priority.
Warnings, overlap examples and input traces identify an explicit priority
when it decides an equal-length match.
