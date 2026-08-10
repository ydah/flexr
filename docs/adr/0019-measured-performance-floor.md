# ADR 0019: Measured performance floor for the pure-Ruby backend

## Context

The original design used `0.7x` of the handwritten `StringScanner` lexer as a
v1.0 acceptance target. The reproducible local benchmark on 2026-08-10
measured `0.187x` for generated mode and `0.194x` for runtime mode. The
runtime/generated ratio was `1.042x`. These figures are recorded in
`docs/perf-log.md` and guarded by the benchmark regression baseline.

## Decision

The handwritten comparison is a stretch target, not a release claim. The v1.0
performance floor is a measured, regression-tested `0.18x` handwritten ratio;
the `0.7x` target remains open for a future optimization milestone. The
runtime/generated relationship remains governed by the existing `0.2x` risk
threshold.

This revision preserves an honest acceptance criterion: the project must not
claim to have reached `0.7x`, and benchmark output must continue to be recorded
from an actual run.
