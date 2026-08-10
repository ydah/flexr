---
title: Parser integration
description: Return flexr tokens to Racc, Lrama, or a custom parser loop.
---

The lexer/parser boundary should be explicit: the lexer owns characters and locations; the parser owns grammar and recovery.

## Racc protocol

For a Racc parser, expose `racc_next_token` as a pair of token kind and semantic value:

```ruby
def racc_next_token
  token = @lexer.next_token
  return [false, false] if token.nil?

  [token.type, token.value]
end
```

Declare the token names in both the lexer and parser grammar. Keep EOF behavior in one adapter rather than duplicating it in every action.

## Lrama protocol

Lrama integrations use the same basic token/value contract. The example in [`examples/with_lrama`](https://github.com/ydah/flexr/tree/main/examples/with_lrama) shows the complete wiring.

`emits` is useful for diagnostics and parser integration, but it does not replace the parser grammar's token declarations. See [tokens and locations](/flexr/reference/tokens-and-locations/) for return shapes.
