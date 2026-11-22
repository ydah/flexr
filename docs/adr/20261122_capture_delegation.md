# ADR: Delegate the exact captured source range to a child lexer

- ステータス: 採用
- 決定日: 2026-11-22
- 関連: [#85](https://github.com/ydah/flexr/pull/85), [20261122_named_captures_of_selected_rule.md / Decision](20261122_named_captures_of_selected_rule.md#%E6%B1%BA%E5%AE%9A)

## コンテキスト

An HTML lexer in Flexr 2.2 can capture a script body and send it to a JavaScript
lexer. The same text can occur more than once in the host match. Positioning
tokens by searching for the captured string would therefore be ambiguous.
`Flexr::Runtime#delegate` has access to the selected group's byte range.

## 決定

Use `delegate(ChildLexer, capture: :name)` in a matched default-channel rule
to give a child lexer just the capture's original byte range. The child runs
its rules and actions independently under the parent's resource limits and
keeps its own lexical state. Translate its token positions and lexical errors
to the host source.

Publish child tokens only after the child scan succeeds. Drain those tokens
in order through the parent's normal token APIs before advancing to the next
host rule. The host action can then emit a token that follows the child tokens.

## 決定しないこと

See [the contextual lexer implementation notes](../implementations/20261122_contextual_lexer_runtime.md#capture-delegation)
for staging and standalone helper selection.

## 検討した代替案

Embedding the child rules in the host would couple the two sets of states and
actions. Re-tokenizing a detached string in the parser would also require the
parser to map child positions back to the original source and interleave
results from both lexers.

## 影響

A single stream retains accurate source coordinates and the order of both
languages. The child scan completes before publishing its first token.
Host and child must use compatible encodings and token representations.
See [capture delegation in rule actions](../reference/actions.md#delegate-a-capture-to-another-lexer).
