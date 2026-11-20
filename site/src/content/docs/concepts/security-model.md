---
title: Security model
description: Understand the code-execution boundary around flexr specifications and generated lexers.
---

flexr specifications are Ruby programs. Rule actions, `--eval`, and generated actions can execute arbitrary Ruby with the permissions of the process that runs them.

## Safe operating assumptions

- Do not run an untrusted `.flexr.rb` file.
- Treat generated Ruby as executable source and review it before deployment.
- Use `flexr check` for diagnostics, not as a sandbox.
- Keep build-time inputs and generator versions pinned in CI.

The Playground executes real Ruby in a separate worker using a virtual filesystem.
The application does not upload source or input; share links store them in a URL
fragment and do not run automatically. Review shared source before selecting Run.

Runs have a five-second timeout and can be stopped immediately. Input size,
automaton construction, and output are bounded. The page restricts network access
and sanitizes output, but a worker is not a complete hostile-code or memory
sandbox. Ruby actions can modify their VM and access worker JavaScript. Parsing a
specification does not make its actions safe.
