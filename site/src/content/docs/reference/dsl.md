---
title: DSL reference
description: The stable lexer specification methods and their role.
---

| API | Purpose |
| --- | --- |
| `rule(pattern, skip: false, emit: nil, followed_by: nil)` | Register a matching rule and action |
| `on_eof` | Define end-of-input behavior |
| `emits(*kinds)` | Declare token kinds for diagnostics and parser integration |
| `state(name)` | Define a named start condition |
| `all_states` | Apply a rule to every state |
| `backend(name)` | Choose `table`, `direct`, or `auto`; `firstmatch` is experimental |
| `token_kind(name)` | Choose the token return shape |
| `encoding(name)` | Select the input encoding contract |
| `option(name)` | Enable an explicit compiler option |
| `accel(name)` | Configure acceleration where compatible |

Rules are evaluated using [longest-match semantics](/flexr/concepts/matching-semantics/). The repository's [DSL reference](https://github.com/ydah/flexr/blob/main/docs/reference/dsl.md) includes option defaults and examples.
