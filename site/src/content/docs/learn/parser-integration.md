---
title: Parser integration
description: Return flexr tokens to Racc, Lrama, or a custom parser loop.
---

The lexer/parser boundary should be explicit: the lexer owns characters and locations; the parser owns grammar and recovery.

## Racc protocol

A Racc parser can forward requests from its `next_token` method to the
Flexr lexer's `racc_next_token` method. It returns a pair of token kind and
semantic value, with `[false, "$end"]` at EOF.

```ruby
def next_token
  @lexer.racc_next_token
end
```

Declare the token names in both the lexer and parser grammar. Generate a working project with `flexr new NAME --parser racc`. [Racc calculator tutorial](https://github.com/ydah/flexr/blob/main/docs/tutorial/build-a-calculator-parser.md#racc).

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

Lrama generates C. The generated flexr project feeds the lexer's token kinds and values to the compiled parser. Start with `flexr new NAME --parser lrama` and a C compiler. [Lrama calculator tutorial](https://github.com/ydah/flexr/blob/main/docs/tutorial/build-a-calculator-parser.md#lrama).

`emits` is useful for diagnostics and parser integration, but it does not replace the parser grammar's token declarations. See [tokens and locations](/flexr/reference/tokens-and-locations/) for return shapes.
