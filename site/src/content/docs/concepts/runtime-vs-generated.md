---
title: Runtime vs generated
description: Choose between interpreting a specification and deploying generated Ruby.
---

Runtime and generated mode are two delivery paths for the same lexer design.

| Question | Runtime | Generated |
| --- | --- | --- |
| Fastest edit/run loop? | Yes | No regeneration step |
| Smallest deployed dependency? | No | Standalone: yes |
| Easy to inspect output? | Specification and runtime | Ruby artifact |
| Recommended parity check? | Source of truth | Compare token stream |

Use the runtime for development and tests, then generate and compare before deployment. Do not assume a generated file is safe merely because it is generated: actions remain Ruby code.
