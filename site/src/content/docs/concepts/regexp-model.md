---
title: Regexp model
description: Learn which Ruby regexp constructs flexr can compile into a finite automaton.
---

flexr compiles regular languages into an automaton. Literals, concatenation, alternation, greedy `*`, `+`, `?`, bounded repetition, character classes, and supported Unicode properties are the useful core.

| Construct | Status | Alternative |
| --- | --- | --- |
| Literal, concatenation, alternation | Supported | — |
| `*`, `+`, `?` | Supported | Greedy matching |
| `{n,m}` | Supported | Keep bounds explicit |
| Lookahead / lookbehind | Unsupported | `followed_by:` or a state/action |
| Backreferences | Unsupported | Split the rule or validate in an action |
| Open repetition `{n,}` | Unsupported | Use a separate rule/action |
| Capturing groups | Accepted with a diagnostic | Use `(?:...)` for intent |

Run `flexr check` before relying on a construct. The [regexp reference](https://github.com/ydah/flexr/blob/main/docs/reference/regexp.md) records the implementation-level boundaries.
