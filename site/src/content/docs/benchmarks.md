---
title: Benchmarks
description: Read reproducible measurements without confusing a benchmark with a promise.
---

Benchmark results depend on Ruby, hardware, input distribution, backend, and table shape. The repository records commands, input conditions, measurements, and limitations in [`docs/perf-log.md`](https://github.com/ydah/flexr/blob/main/docs/perf-log.md).

## Reference JSON

Measured on 2026-11-22 with Ruby 4.0.9 on arm64 macOS, using 140,000 bytes of input and 50,000 emitted tokens. These are medians from three runs per engine.

| Engine | Runtime / handwritten | Generated / handwritten | Generated / runtime |
|---|---:|---:|---:|
| Interpreter | 0.263x | 0.292x | 1.104x |
| YJIT | 0.693x | 0.718x | 1.059x |
| ZJIT | 0.260x | 0.264x | 1.020x |

Start with `auto` and use [the reproduction commands](https://github.com/ydah/flexr/blob/main/docs/perf-log.md#2026-11-22-frozen-scan-eof-check) to measure the workload you plan to deploy.
