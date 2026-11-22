# ADR: Classify keywords after the base rule wins

- ステータス: 採用
- 決定日: 2026-11-22
- 関連: [#72](https://github.com/ydah/flexr/pull/72)

## コンテキスト

Flexr lexers can list reserved words as separate literal rules next to a broader identifier rule.
Each spelling then participates in rule selection and contributes paths to the automaton, even when only the token type needs to change.
Reordering overlapping rules may affect which text or action the lexer selects.

## 決定

Associate `keywords` with the declared `emit:` type of default-channel rules.
Remap a winning rule's exact lexeme to its keyword token type after selection.
Keep the winning rule's match length, value, location, and lexical state.
A dynamic action keeps control of its emitted token type.

Require every spelling to match a full body of an eligible base rule and expose the base and mapped types to parser integration.
Require a full first match for base rules that use `firstmatch`.

## 決定しないこと

The [generated rule annotations record](../implementations/20261122_generated_rule_annotations.md#keyword-tables) describes artifact storage and emission paths.

## 検討した代替案

Adding one literal rule for each keyword makes the spelling part of rule precedence and adds paths to the automaton.
Remapping only the winning declarative rule supports a grammar that still wants a separate rule to win on the same input.

## 影響

An identifier rule can emit `:IF` for `if` and `:IDENT` for `ifx` with the same matching language.
The compiler can diagnose a spelling that the base rule can never emit.
Use a separate rule when a keyword needs to change match precedence or run its own action.
