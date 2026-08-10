---
title: Regexp compatibility
description: A practical compatibility guide for Ruby regexp constructs.
---

The compiler accepts the regular-expression subset that can be represented by its automaton. Supported constructs include literals, concatenation, alternation, greedy repetition, bounded repetition, character classes, anchors in supported positions, and supported Unicode properties.

Lookaround, backreferences, and open-ended repetition are not DFA-compatible. Capturing groups are accepted with a diagnostic and do not provide capture values to actions.

When in doubt, run:

```sh
bundle exec flexr check lexer.flexr.rb
```

The repository's [regexp matrix](https://github.com/ydah/flexr/blob/main/docs/reference/regexp.md) lists diagnostic codes, limits, inline-option behavior, and alternatives.
