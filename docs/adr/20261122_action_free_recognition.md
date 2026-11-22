# ADR: Recognize rules at a byte offset without running actions

- ステータス: 採用
- 決定日: 2026-11-22
- 関連: [#79](https://github.com/ydah/flexr/pull/79)

## コンテキスト

The [Lrama standalone experiment](../perf-log.md#lrama-standalone-recognizer-experiment-2026-11-20) had to coordinate private Flexr scanner positions with the upstream cursor.
An embedded matcher needs to recognize a rule using the original string and the caller's byte offset.
The action may change state, emit a different token from the rule's static identity, or have effects that recognition cannot undo.
A separately written matcher can pick a different rule at anchors or trailing context.

## 決定

Expose `Lexer.recognizer(state:)` as an immutable, Ractor-shareable snapshot of a compiled lexical state.
`Flexr::Recognizer#match` reads a `String` at an absolute byte offset and returns, or yields, the selected rule identity and exclusive body end.
Use the declared `emit:` type or, for another action or a skip, the source-rule index.
Keyword remapping belongs to token emission.

Keep longest-match ranking, trailing context, line anchors, and subject encoding consistent with normal DFA rule selection.
Construction rejects `firstmatch` because its native selection follows different rule and regexp ordering.

## 決定しないこと

Streaming, recovery, and per-lexer limits belong to ordinary lexer instances.
Snapshot preparation and allocation measurements are in the [parser-facing scan paths record](../implementations/20261122_parser_facing_scan_paths.md#recognizer).

## 検討した代替案

Reusing ordinary token consumption would require moving the lexer's separate cursor and suppressing its actions.
A fixed-state recognition API prevents changes to lexer state while letting the caller own the input cursor.

## 影響

Embedding code can reuse compiled rules without wiring up a second cursor or running actions.
The caller supplies a string and must advance the cursor itself, including after any allowed empty match.
