---
title: Public API and stability
description: Separate stable user APIs from experimental and internal implementation details.
---

## Public and stable

`Flexr::Lexer`, the lexer DSL, runtime token/location structures, the documented CLI, and `Flexr::RakeTask` are the supported entry points for normal use.

## Experimental

The `firstmatch` backend and any option explicitly marked experimental may change behavior or API shape between releases. Opt in deliberately and test the resulting token stream.

## Internal

`Flexr::IR`, `Flexr::Automaton`, `Flexr::Codegen`, parser internals, and generated implementation helpers are internal. Compatibility is not guaranteed for these namespaces.

Version-specific guarantees live in [compatibility](https://github.com/ydah/flexr/blob/main/docs/reference/compatibility.md) and the [changelog](/flexr/changelog/).
