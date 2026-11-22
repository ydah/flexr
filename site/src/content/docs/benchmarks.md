---
title: Benchmarks
description: Read reproducible measurements without confusing a benchmark with a promise.
---

Benchmark results depend on Ruby, hardware, input distribution, backend, and table shape. The repository records commands, input conditions, measurements, and limitations in [`docs/perf-log.md`](https://github.com/ydah/flexr/blob/main/docs/perf-log.md).

## Reference JSON

Measured on 2026-11-22 with Ruby 4.0.9 on arm64 macOS, using 140,000 bytes of input and 50,000 emitted tokens. These are medians from three runs per engine.

| Engine | Runtime / handwritten | Generated / handwritten | Generated / runtime |
|---|---:|---:|---:|
| Interpreter | 0.259x | 0.282x | 1.088x |
| YJIT | 0.702x | 0.728x | 1.012x |
| ZJIT | 0.262x | 0.269x | 1.010x |

Start with `auto` and use [the reproduction commands](https://github.com/ydah/flexr/blob/main/docs/perf-log.md#2026-11-22-packed-lookup-and-token-loop-allocations) to measure the workload you plan to deploy.
