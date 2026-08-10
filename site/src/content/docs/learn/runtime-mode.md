---
title: Runtime mode
description: Use a lexer specification directly with the flexr runtime.
---

Runtime mode loads the Ruby specification and interprets its compiled automaton. It is the shortest feedback loop for tests and application development.

```ruby
require 'flexr'

class Lexer < Flexr::Lexer
  token_kind :struct
  rule(/[ \t\n]+/, skip: true)
  rule(/[0-9]+/) { emit :INTEGER, text.to_i }
  rule(/\+/) { emit :PLUS }
end

lexer = Lexer.new('12 + 3')
lexer.each_token { |token| p token }
```

Use runtime mode when the specification is the source of truth and startup compilation is acceptable. It also makes it easy to exercise actions and location tracking in unit tests.

### Input and iteration

`next_token` returns one token at a time. `each_token` iterates until EOF. The exact return shape depends on `token_kind`; see [tokens and locations](/flexr/reference/tokens-and-locations/).

### Validate early

Run `flexr check SPEC` in CI. It can report unsupported regexp constructs, unreachable rules, empty matches, undeclared emitted tokens, and automaton-size warnings before runtime.

For the complete API contract, see the repository's [runtime reference](https://github.com/ydah/flexr/blob/main/docs/reference/runtime.md).
