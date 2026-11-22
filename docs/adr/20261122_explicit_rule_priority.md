# ADR: Apply explicit rule priority only to equal-length matches

- Status: Accepted
- Decision date: 2026-11-22
- Related: [#74](https://github.com/ydah/flexr/pull/74)

## Context

Flexr's longest-match rule gives precedence to source order when two rules match the same length.
Reusable rule sets can put the tied rules in different declarations, making it difficult to express a local precedence choice by reordering them.
See [20260809_leftmost_longest.md / Decision](20260809_leftmost_longest.md#decision).

## Decision

For `table`, `direct`, and `auto`, rank candidates by total matched byte length including trailing context, then by highest integer `priority:`, then by source order.
Omitted priority counts as zero.
Reject nonzero priority for `firstmatch`, where rule order is the matching contract.

## Out of scope

The [generated rule annotations record](../implementations/20261122_generated_rule_annotations.md#rule-priority) describes how generated artifacts store annotations and how diagnostics expose them.

## Alternatives considered

Keeping only source order would require moving shared rule declarations to resolve a tie.
Comparing priority before length would let a high-priority `if` rule take a prefix of `ifx` and change the longest-match contract.

## Consequences

A later rule can win a deliberate tie while longer tokens keep precedence.
Existing longest-match rules with the same priority keep their original order.
Specifications using nonzero priority must use a longest-match backend and a runtime that understands the priority annotation.
