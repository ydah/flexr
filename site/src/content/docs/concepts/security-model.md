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

The hosted playground currently uses fixed fixtures and does not execute arbitrary Ruby. A future WASM worker must keep that boundary explicit, enforce resource limits, and never imply that parsing source is equivalent to sandboxing actions.
