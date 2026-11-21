---
title: Matching semantics
description: Understand how flexr chooses a rule when several rules accept the same position.
---

With the default longest-match backends, flexr selects the rule that consumes the most bytes at each input position. If multiple rules consume the same number, the rule defined first wins.

```ruby
rule(/==/) { emit :EQ }
rule(/=/) { emit :ASSIGN }
```

Input `==` produces `EQ`, regardless of the order above. Equal-length alternatives are resolved by definition order, so putting keyword rules before a broad identifier rule is the conventional way to reserve keywords.

The stable `firstmatch` backend instead selects the first rule with a match at the current position. Ruby regexp alternation order applies within that rule, so `/a|ab/` matches `a` on input `ab`. Select this behavior explicitly with `backend :firstmatch`.

The [playground](/flexr/playground/) shows candidates and the winner for each scan step.
