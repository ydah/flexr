---
title: Generation
description: Generate deterministic Ruby from the same specification used at runtime.
---

Generation turns a `.flexr.rb` specification into Ruby source. The generated lexer keeps rule actions as Ruby code, so review the specification and generated artifact as executable code.

```sh
bundle exec flexr check lexer.flexr.rb
bundle exec flexr generate lexer.flexr.rb -o lexer.rb
```

The generator can use `table`, `direct`, or `auto` backends. `firstmatch` is experimental and requires an explicit option because it does not preserve the usual longest-match contract.

## Runtime dependencies

| Mode | Build-time dependency | Runtime dependency |
| --- | --- | --- |
| Runtime | `flexr` | `flexr` |
| Generated | generator and `flexr` | usually `flexr` |
| Standalone generated | generator and `flexr` | generated file only |

Use standalone output only when the generated file is verified and the deployment boundary requires no runtime gem. Confirm the generated file does not load the runtime before publishing it.

## Reproducible artifacts

Treat the generator version, Ruby version, backend, encoding, and Unicode data snapshot as part of the artifact contract. If generated Ruby is committed, regenerate it in CI and fail on a diff.

See [runtime vs generated](/flexr/concepts/runtime-vs-generated/) and the repository's [generated artifact reference](https://github.com/ydah/flexr/blob/main/docs/reference/generated-artifacts.md).
