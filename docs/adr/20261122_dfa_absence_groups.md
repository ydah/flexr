# ADR: Define absence groups to match text with no forbidden substring

- Status: Accepted
- Decision date: 2026-11-22
- Related: [#70](https://github.com/ydah/flexr/pull/70)

## Context

Flexr users can write delimiter rules with Ruby's `(?~X)` syntax.
The lexer needs to agree on whether a rule accepts an input in runtime, generated, and standalone modes.
Ruby 4.0.9's `Regexp#match` accepts empty input for `\A(?~a?)\z`, while every string contains a match for `a?` under the regular-language definition.

## Decision

Define `(?~X)` as the strings that contain no substring matched by `X`.
Apply the definition to valid UTF-8 scalar strings or to arbitrary byte strings for binary input.
If `X` accepts the empty string, the group accepts no input.
The surrounding rule keeps its normal anchors, match ranking, and empty-match policy.

Support absence in the bodies of `table`, `direct`, and `auto` rules and in DFA-evaluated `followed_by:` expressions.
Reject `firstmatch` rule bodies containing absence so they cannot silently use different semantics.

## Out of scope

The construction and state limit for the automaton are recorded in [DFA absence groups](../implementations/20261122_dfa_absence_groups.md).

## Alternatives considered

Delegating absence to Ruby's matcher would preserve Ruby's treatment of nullable operands.
It would also couple the accepted language to host Ruby and would make static DFA analysis disagree with matching for the empty-input example.

## Consequences

Users can exclude a terminator with the same meaning in all three execution modes.
Porting a Ruby regexp that excludes a nullable expression may require rewriting the rule.
The details are in [absence groups](../reference/regexp.md#absence-groups).
