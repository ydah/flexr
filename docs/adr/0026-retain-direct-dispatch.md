# ADR 0026: Retain direct dispatch after the state cases experiment

## Context

The [state dispatch experiment](../perf-log.md#state-specific-dispatch-experiment-2026-11-20)
compared table dispatch, flattened direct dispatch, and per-state Ruby
`case` branches. It checked token equality before timing on a 140,000-byte
JSON input using Ruby 4.0.9 on arm64-darwin.

| Engine | Direct MB/s | State cases MB/s |
|---|---:|---:|
| Interpreter | 1.729 | 1.709 |
| YJIT | 2.796 | 2.768 |
| ZJIT | 0.425 | 0.483 |

## Decision

Keep the existing direct backend and `auto` policy. The interpreter and YJIT
samples favored direct dispatch. The ZJIT sample favored state cases, but
needs longer warm-up measurements before it can justify maintaining another
backend. Keep the experiment and its equivalence checks as a benchmark for
future work.
