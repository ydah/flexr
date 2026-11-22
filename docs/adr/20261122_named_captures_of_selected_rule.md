# ADR: Expose named captures from the selected rule body

- ステータス: 採用
- 決定日: 2026-11-22
- 関連: [#82](https://github.com/ydah/flexr/pull/82), [#100](https://github.com/ydah/flexr/pull/100)

## コンテキスト

The longest-match DFA recognizes whole rule bodies and can accept the same body through several group paths.
For example, `/(?<head>a|aa)(?<tail>a+)/` and `/(?<head>aa|a)(?<tail>a+)/` accept the same `aaa` body but give `head` different values under Ruby 4.0.9's `Regexp#match`.
An action needs deterministic subgroup values without letting subgroup choices alter token selection.

## 決定

Select the rule and its body using the backend's normal matching semantics.
In longest-match modes, resolve named groups within that body using Ruby's subgroup precedence and the character classes used for rule matching.
`firstmatch` uses the groups of its selected native match.

Expose the result as a frozen hash from `captures` during the action.
Groups describe the body before action controls change its span and exclude trailing context and text from `more`.

## 決定しないこと

The extraction implementation is described in the [named capture replay record](../implementations/20261122_replay_named_regexp_captures.md).
The [regexp reference](../reference/regexp.md#captures) specifies which groups are exposed.

## 検討した代替案

Using Ruby to choose the rule body as well as its groups could change longest-match behavior because native alternatives have their own order.
The [tagged capture experiment](../perf-log.md#tagged-captures) shows that recovering subgroup choices within a DFA requires extra information to resolve otherwise identical accepting paths.
A different extraction algorithm can serve the same API if it preserves the selected body and its subgroup values.

## 影響

Actions can read subgroups with the same token boundaries and positions as an equivalent rule without named groups.
An ambiguous subgroup follows Ruby's rules within that boundary.
A generated artifact that uses named groups requires a runtime that supports captures.
