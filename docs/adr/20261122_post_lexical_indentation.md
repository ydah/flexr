# ADR: Emit indentation tokens from the parser-visible stream

- ステータス: 採用
- 決定日: 2026-11-22
- 関連: [#83](https://github.com/ydah/flexr/pull/83), [20261122_lexer_checkpoints.md / Decision](20261122_lexer_checkpoints.md#%E6%B1%BA%E5%AE%9A)

## コンテキスト

In Flexr 2.2 a rule can discard whitespace while the parser still needs a
block boundary at the next visible token. That boundary depends on earlier
indentation widths and open brackets. Bracket tracking also needs the original
matched lexeme because the token action can emit a different value.

## 決定

Let the `indentation` declaration name the newline, indent, and dedent token
types and define bracket pairs and tab width. Process layout using visible
content and the original bracket lexemes after a rule has matched. Ignore
blank lines, comment-only lines, and line breaks inside configured brackets.

Emit layout tokens before the next visible content token and close the
remaining levels at EOF. Checkpoints capture pending layout tokens and layout
state. An indentation lexer can seek to byte zero and uses a checkpoint to
return to another position.

## 決定しないこと

The order of runtime wrappers and the data used to track layout are described
in [the contextual lexer implementation notes](../implementations/20261122_contextual_lexer_runtime.md#indentation).

## 検討した代替案

An ordinary newline rule can observe indentation on one line. It cannot
compare it with an arbitrarily deep layout stack in the DFA. Leaving the
work to the parser would require every caller to reconstruct discarded
whitespace and bracket lexemes.

## 影響

The parser receives indent and dedent events in order. Structured tokens
carry a zero-width location at the content boundary or at EOF. Layout state
adds information to each checkpoint. See the [indentation reference](../reference/runtime.md#indentation-tokens).
