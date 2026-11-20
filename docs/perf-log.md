# Performance log

## State-specific dispatch experiment (2026-11-20)

`benchmark/state_dispatch.rb` compares generated table dispatch, the existing
flattened direct representation, and per-state Ruby `case` branches. It checks
token equality before timing. The transition test compares every state/byte pair.
It is a development experiment and does not add a public backend.

```sh
bundle exec ruby benchmark/state_dispatch.rb --iterations 5
RUBYOPT=--yjit bundle exec ruby benchmark/state_dispatch.rb --iterations 5
RUBYOPT=--zjit bundle exec ruby benchmark/state_dispatch.rb --iterations 5
```

Measured on Ruby 4.0.9, arm64-darwin25, built-in 140,000-byte JSON input:

| Engine | Table MB/s | Direct MB/s | State cases MB/s |
|---|---:|---:|---:|
| Interpreter | 1.170 | 1.729 | 1.709 |
| YJIT | 1.922 | 2.796 | 2.768 |
| ZJIT | 0.458 | 0.425 | 0.483 |

These short local samples are not release qualification or confidence intervals.
State cases do not improve on the existing direct representation in the
interpreter or YJIT samples, and ZJIT needs longer warm-up investigation.
Keep the existing direct backend and `auto` selection until repeatable gains
justify adding and maintaining another backend. No regression baseline changes
are warranted by this experiment.

The benchmark harness reports bytes/s, tokens/s, and allocations per token.
Numbers are intentionally recorded only after running the harness on the
target Ruby and hardware; no unmeasured figures are presented as guarantees.

Run:

```sh
ruby -Ilib benchmark/run.rb
```

For independent Ruby interpreter, YJIT, and ZJIT processes, run
`bundle exec rake bench:matrix`. The JSON report checks that each engine is
actually enabled and marks unavailable builds explicitly. It does not replace
the baseline with a different engine's measurements. Use
`ruby benchmark/matrix.rb --input-file PATH --iterations 3` for a custom input.

`bundle exec rake bench:profile` provides an optional TracePoint profile without
an extra gem. It excludes class loading and compilation after a warm-up run and
reports non-overlapping time in scanning, actions, token handling, locations,
and other work for runtime and generated modes. Scanning includes the DFA byte
loop and matcher overhead; token handling includes `next_token`, `emit`, and
text materialization; locations include position updates and lazy location
construction. These are instrumented costs: TracePoint adds substantial
overhead and changes JIT behavior, so do not compare these times with normal
throughput. Use `ruby benchmark/profile.rb --input-file PATH --iterations 1`
to profile a custom input. `FLEXR_BENCHMARK_ITERATIONS` controls either rake task.

The JSON result includes `mb_per_s`, `tokens_per_s`, and cumulative Ruby
`allocations_per_token` for runtime, generated, and handwritten modes. JSON
also records each Flexr mode as a ratio against the handwritten baseline.
The large deterministic corpus can be materialized when needed:

```sh
ruby benchmark/corpora/generate_json.rb > benchmark/corpora/json_10mb.json
ruby -Ilib benchmark/run.rb --spec examples/json/lexer.flexr.rb \
  --input-file benchmark/corpora/json_10mb.json
```

## 2026-08-10

On the local Ruby 4.0.0 environment, the default 140,000-byte JSON input and
three measured iterations produced the following sample. These are recorded
observations, not cross-machine guarantees.

| mode | MB/s | tokens/s | allocations/token | handwritten ratio |
|---|---:|---:|---:|---:|
| runtime | 1.671 | 596,789 | 5.201 | 0.194x |
| generated | 1.604 | 572,954 | 4.201 | 0.187x |
| handwritten | 8.597 | 3,070,499 | 3.4 | 1.000x |

This sample is above the v1.0 measured regression floor of 0.18x, but below the
0.7x handwritten stretch target. The measured ratios are recorded explicitly
rather than presented as a claim that the stretch target has been reached.
Runtime is 1.042x generated in this sample, above the 0.2x runtime-mode risk
threshold. See ADR 0019 for the target revision.

### Byte/token cost estimate

The same 10 MB JSON corpus was measured with compact records and with 100
padding spaces after each numeric value. The compact sample had 3,448,271
tokens; the padded sample had 775,191 tokens. Solving
`elapsed = c_byte * bytes + c_token * tokens` from the two measurements gives
the following local estimates (one iteration, `backend :direct`):

| mode | c_byte | c_token |
|---|---:|---:|
| runtime | 619 ns/byte | 1.090 us/token |
| generated | 611 ns/byte | 0.983 us/token |

The padded corpus can be reproduced with
`FLEXR_JSON_PADDING_BYTES=100 ruby benchmark/corpora/generate_json.rb`.

## 2026-08-12

After adding bounded scanning and the compiler/generated-runtime
optimizations, the same Ruby 4.0.0 host produced this three-iteration sample:

| mode | MB/s | tokens/s | allocations/token | handwritten ratio |
|---|---:|---:|---:|---:|
| runtime | 1.603 | 572,508 | 5.2 | 0.203x |
| generated | 1.607 | 573,857 | 5.21 | 0.203x |
| handwritten | 7.902 | 2,822,254 | 3.4 | 1.000x |

Both the portable baseline comparison and the ordinary 0.18x performance
floor pass in this sample. `auto` acceleration now stops trying a region after
repeated short runs, while explicit `strscan` and `regexp` modes remain fixed
choices for workloads that have measured long runs.

## 2026-11-20

On Ruby 4.0.9 (`3e93b23afc`, arm64-darwin25), revision `0391a6e`, the default
140,000-byte JSON input produced 50,000 tokens. `ruby benchmark/matrix.rb
--iterations 3` warmed each mode for three iterations, then measured three
iterations in a separate process per engine. All three engines were available.
This is one local sample from a development session, not an isolated performance
qualification or a reason to raise the regression baseline.

| Engine | Mode | MB/s | allocations/token | handwritten ratio |
|---|---|---:|---:|---:|
| Interpreter | runtime | 1.700 | 5.200 | 0.204x |
| Interpreter | generated | 1.668 | 5.210 | 0.200x |
| Interpreter | handwritten | 8.343 | 3.400 | 1.000x |
| YJIT | runtime | 4.789 | 5.200 | 0.464x |
| YJIT | generated | 2.894 | 5.210 | 0.281x |
| YJIT | handwritten | 10.316 | 3.400 | 1.000x |
| ZJIT | runtime | 1.958 | 5.200 | 0.203x |
| ZJIT | generated | 0.414 | 5.210 | 0.043x |
| ZJIT | handwritten | 9.639 | 3.400 | 1.000x |

The input SHA-256 is
`f15489cc8fa286cd365fb167b3f99d3d216dc90c0de6279fe9f36c8d2215d7a7`.
ZJIT's generated result is slow in this short run; it needs investigation with
longer warm-up before drawing conclusions about steady-state performance.

A separate `ruby benchmark/profile.rb --iterations 1` run reported the
following instrumented times:

| Mode | Scanning | Actions | Token handling | Locations | Other |
|---|---:|---:|---:|---:|---:|
| runtime | 2.495 s | 0.470 s | 1.479 s | 0.132 s | 0.002 s |
| generated | 2.669 s | 0.459 s | 1.466 s | 0.132 s | 0.001 s |

Scanning is the largest category in this instrumented sample, followed by token
handling. These categories identify work to investigate; they do not establish
uninstrumented phase percentages or prove a particular optimization will help.
