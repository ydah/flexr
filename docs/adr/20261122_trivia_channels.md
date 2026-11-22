# ADR: Preserve trivia without changing the default token stream

- ステータス: 採用
- 決定日: 2026-11-22
- 関連: [#73](https://github.com/ydah/flexr/pull/73)

## コンテキスト

A Flexr parser consumes a stream of semantic tokens.
A formatter or editor using the same rules can also need whitespace, comments, and their locations.
Declaring those matches with `skip: true` loses the text and coordinates before these clients can consume them.

## 決定

Route tokens to the selected rule's channel after matching and its action.
Keep default token iteration and Racc consumption on the default channel.
Offer `tokens(channels: :all)` to collect named trivia channels in source order, and keep `channel: :skip` equivalent to `skip: true` in every stream.

Expose leading trivia on structured tokens without changing their data members.
Keep array and yield tokens as two-element pairs.
Preserve the trivia byte ranges for buffered and streaming inputs.

## 決定しないこと

The [generated rule annotations record](../implementations/20261122_generated_rule_annotations.md#trivia-channels) describes the payload and standalone support.

## 検討した代替案

Replacing skip rules with trivia would collect text that existing lexers deliberately discard.
Sending trivia through default iteration would require every parser adapter to filter previously invisible tokens.
Separate access to named channels lets source tools opt in while parser grammars keep their existing input.

## 影響

One lexer can serve a parser and a source-preserving tool without changing rule precedence or state transitions.
A full-stream consumer must collect from a fresh lexer and mark the text it wants to preserve as trivia.
The [trivia channels reference](../reference/runtime.md#consumption) describes how both views consume input.
