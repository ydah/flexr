---
title: Benchmarks
description: Read reproducible measurements without confusing a benchmark with a promise.
---

Benchmark results depend on Ruby, hardware, input distribution, backend, and table shape. The repository records commands, input conditions, measurements, and limitations in [`docs/perf-log.md`](https://github.com/ydah/flexr/blob/main/docs/perf-log.md).

## Reference JSON

Measured on 2026-11-22 with Ruby 4.0.9 on arm64 macOS, using 140,000 bytes of input and 50,000 emitted tokens. These are medians from three runs per engine.

| Engine | Runtime / handwritten | Generated / handwritten | Generated / runtime |
|---|---:|---:|---:|
| Interpreter | 0.223x | 0.234x | 1.036x |
| YJIT | 0.555x | 0.519x | 0.958x |
| ZJIT | 0.208x | 0.202x | 0.972x |

Start with `auto` and use [the reproduction commands](https://github.com/ydah/flexr/blob/main/docs/perf-log.md#2026-11-22-generated-frozen-input-scan) to measure the workload you plan to deploy.
