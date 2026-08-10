---
title: Diagnostics
description: Find the reason a specification is rejected or warned about.
---

Diagnostics are part of the authoring experience, not just compiler failures. `flexr check` can report:

- unreachable rules and states without rules;
- empty-string matches;
- unsupported regexp constructs;
- undeclared emitted token kinds;
- variable-length trailing context;
- acceleration incompatibility;
- large transition tables and compile-time risks.

Use the code in the message to search the repository's [diagnostics catalog](https://github.com/ydah/flexr/blob/main/docs/reference/diagnostics.md). Each entry explains why it happens, how to fix it, and when ignoring it is reasonable.
