# ADR 0027: Set performance targets per Ruby engine

## Context

[ADR 0019](0019-measured-performance-floor.md) established a measured release
floor for the pure-Ruby lexer. The [engine matrix](../perf-log.md#2026-11-20)
shows that interpreter, YJIT, and ZJIT results differ substantially. Generated
mode can also be slower than runtime mode on the same engine and input.

## Decision

Measure each engine in a separate Ruby process with the same input and lexer.
Verify equivalent token sequences and record the Ruby version, machine,
workload, and sample size with the throughput and allocation results.

| Engine | JSON throughput relative to handwritten |
|---|---|
| Interpreter | Keep the `0.18x` local release floor and target `0.30x`. |
| YJIT | Target `0.50x`, with a stretch target of `0.70x`. |
| ZJIT | Track throughput and allocations, and investigate reproducible regressions. |

On the reference JSON workload, target a generated/runtime throughput ratio
of at least `1.0` on each engine and at most 3.4 allocations per emitted token
in runtime mode. Measure other lexer workloads individually. Run timing
comparisons on a fixed reference machine and keep the portable CI gate from
[ADR 0019](0019-measured-performance-floor.md).

On the reference machine, run
`FLEXR_BENCHMARK_CHECK_MATRIX=1 FLEXR_BENCHMARK_ITERATIONS=10 bundle exec rake bench:matrix`.
The check keeps all three ratio samples for each engine and uses their median.
An unavailable engine or a median below `1.0` fails the check.

For simple scanners on frozen input with scanning guards inactive, generated
`accel :auto` uses the same DFA-only policy as the interpreter fast path. This
avoids lazy region-cache writes in the generated scan loop. The region path
remains available for streaming, guarded input, and explicit `:strscan`.
