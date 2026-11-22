# ADR 0019: Measured performance floor for the pure-Ruby backend

## Context

The original design used `0.7x` of the handwritten `StringScanner` lexer as a
v1.0 acceptance target. The reproducible local benchmark on 2026-08-10
measured `0.187x` for generated mode and `0.194x` for runtime mode. The
runtime/generated ratio was `1.042x`. These figures are recorded in
`docs/perf-log.md` and guarded by the benchmark regression baseline.

## Decision

The measured, regression-tested interpreter floor is `0.18x` of the handwritten
JSON lexer. [ADR 0027](0027-per-engine-performance-targets.md) defines the
throughput targets for each engine and the generated/runtime comparison.
Benchmark output must come from an actual run.

The absolute floor is enforced by the local release gate. CI uses a portable
variant that keeps the 10% baseline-regression check but omits the absolute
throughput floor because hosted runners are not a stable performance
measurement environment.
