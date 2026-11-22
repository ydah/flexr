---
title: Parser integration
description: Return flexr tokens to Racc, Lrama, or a custom parser loop.
---

The lexer/parser boundary should be explicit: the lexer owns characters and locations; the parser owns grammar and recovery.

## Racc protocol

A Racc parser can call the flexr lexer's `racc_next_token` method from its own `next_token` method.

```ruby
def next_token
  @lexer.racc_next_token
end
```

Declare the token names in both the lexer and parser grammar. Generate a working project with `flexr new NAME --parser racc`. [Racc calculator tutorial](https://github.com/ydah/flexr/blob/main/docs/tutorial/build-a-calculator-parser.md#racc).

## Lrama protocol

Lrama generates C. The generated flexr project feeds the lexer's token kinds and values to the compiled parser. Start with `flexr new NAME --parser lrama` and a C compiler. [Lrama calculator tutorial](https://github.com/ydah/flexr/blob/main/docs/tutorial/build-a-calculator-parser.md#lrama).

`emits` is useful for diagnostics and parser integration, but it does not replace the parser grammar's token declarations. See [tokens and locations](/flexr/reference/tokens-and-locations/) for return shapes.
