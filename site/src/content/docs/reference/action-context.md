---
title: Action context
description: Values and methods available inside a rule action.
---

Actions run in the lexer context. Common methods include:

| API | Use |
| --- | --- |
| `text` / `text_bytesize` | Matched text and its byte length |
| `emit(type, value = text)` | Return a token |
| `skip` | Consume input without emitting a token |
| `echo` | Write the matched text to the configured output |
| `lineno`, `line`, `byte_pos` | Current position information |
| `beginning_of_line?` | Check the start-of-line condition |
| `state`, `push`, `pop`, `begin_state` | Manage lexer states |
| `less(n)` / `more` | Adjust or extend the current match |
| `error!(message)` | Raise a lexer error with location context |

Prefer small, deterministic actions. If an action needs parser state or external services, keep that dependency in an adapter around the lexer.
