---
title: Benchmarks
description: Read reproducible measurements without confusing a benchmark with a promise.
---

Benchmark results depend on Ruby, hardware, input distribution, backend, and table shape. The repository records commands, input conditions, measurements, and limitations in [`docs/perf-log.md`](https://github.com/ydah/flexr/blob/main/docs/perf-log.md).

## Reference JSON

Measured on 2026-11-22 with Ruby 4.0.9 on arm64 macOS, using 140,000 bytes of input and 50,000 emitted tokens. Each row reports the run with the median generated/runtime ratio out of three runs per engine.

| Engine | Runtime / handwritten | Generated / handwritten | Generated / runtime |
|---|---:|---:|---:|
| Interpreter | 0.261x | 0.307x | 1.177x |
| YJIT | 0.717x | 0.763x | 1.064x |
| ZJIT | 0.259x | 0.274x | 1.060x |

Start with `auto` and use [the reproduction commands](https://github.com/ydah/flexr/blob/main/docs/perf-log.md#2026-11-22-cache-the-direct-scan-layout-per-dfa) to measure the workload you plan to deploy.
