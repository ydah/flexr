---
title: Parser integration
description: Return flexr tokens to Racc, Lrama, or a custom parser loop.
---

The lexer/parser boundary should be explicit: the lexer owns characters and locations; the parser owns grammar and recovery.

## Racc protocol

For a Racc parser, forward token requests to `racc_next_token`.
It returns a pair of token kind and semantic value, with `[false, "$end"]` at EOF.

```ruby
def racc_next_token
  @lexer.racc_next_token
end
```

Declare the token names in both the lexer and parser grammar. Keep EOF behavior in one adapter rather than duplicating it in every action.

## Parser token expectations

Pass an array of expected terminal Symbols to `next_token` or `racc_next_token`.
Flexr applies the lexer backend's rule ordering after filtering by `emit:` or a rule-level `emits:` annotation.
Skip rules, trivia channels, and unannotated action blocks remain eligible.

```ruby
# At the start of a Ruby expression, / can begin a regexp literal.
lexer.next_token(expect: %i[REGEXP INTEGER IDENT])
# After an operand, / can be division.
lexer.next_token(expect: %i[DIV PLUS])
```

The parser adapter supplies the array for each request.
See the [Ruby slash and JavaScript template examples on GitHub](https://github.com/ydah/flexr/blob/main/docs/how-to/parser-driven-lexing.md).

## Lrama protocol

Lrama integrations use the same basic token/value contract. The example in [`examples/with_lrama`](https://github.com/ydah/flexr/tree/main/examples/with_lrama) shows the complete wiring.

`emits` is useful for diagnostics and parser integration, but it does not replace the parser grammar's token declarations. See [tokens and locations](/flexr/reference/tokens-and-locations/) for return shapes.
