---
title: Benchmarks
description: Read reproducible measurements without confusing a benchmark with a promise.
---

Benchmark results depend on Ruby, hardware, input distribution, backend, and table shape. The repository records commands, input conditions, measurements, and limitations in [`docs/perf-log.md`](https://github.com/ydah/flexr/blob/main/docs/perf-log.md).

Use the log to reproduce a comparison, not to select a backend from one headline number. Start with `auto`, measure your own workload, then pin a backend only when the evidence justifies the extra configuration.
