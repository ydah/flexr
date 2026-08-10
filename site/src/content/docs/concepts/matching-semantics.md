---
title: Matching semantics
description: Understand how flexr chooses a rule when several rules accept the same position.
---

At each input position, flexr selects the rule that consumes the most characters. If multiple rules consume the same number, the rule defined first wins.

```ruby
rule(/==/) { emit :EQ }
rule(/=/) { emit :ASSIGN }
```

Input `==` produces `EQ`, regardless of the order above. Equal-length alternatives are resolved by definition order, so putting keyword rules before a broad identifier rule is the conventional way to reserve keywords.

The [playground](/flexr/playground/) shows candidates and the winner for each scan step. The `firstmatch` backend is experimental because it changes this selection model.
