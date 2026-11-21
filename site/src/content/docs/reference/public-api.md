---
title: Public API and stability
description: Separate stable user APIs from experimental and internal implementation details.
---

## Public and stable

`Flexr::Lexer`, the lexer DSL, immutable runtime token/location Data records, the documented CLI, and `Flexr::RakeTask` are the supported entry points for normal use.

The `firstmatch` backend is stable and uses rule-order semantics in runtime and generated modes. Select it explicitly with `backend :firstmatch`; no experimental option is required.

## Experimental

Options explicitly marked experimental may change behavior or API shape between releases.

## Internal

`Flexr::IR`, `Flexr::Automaton`, `Flexr::Codegen`, parser internals, and generated implementation helpers are internal. Compatibility is not guaranteed for these namespaces.

Version-specific guarantees live in the [compatibility reference](https://github.com/ydah/flexr/blob/main/docs/reference/compatibility.md) and the release commits.
