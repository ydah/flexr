# Performance log

The benchmark harness reports bytes/s, tokens/s, and allocations per token.
Numbers are intentionally recorded only after running the harness on the
target Ruby and hardware; no unmeasured figures are presented as guarantees.

Run:

```sh
ruby -Ilib benchmark/run.rb
```

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

## 2026-11-20: whole-token acceleration

Ruby 4.0.9 on arm64-darwin-25, the default 140,000-byte JSON corpus, 50,000
emitted tokens, and five warmup plus five measured iterations produced these
sequential local samples. The control checkout was `0391a6e`. The explicit
StringScanner variant adds only `accel :strscan` to the JSON specification.

| accelerator | engine | runtime MB/s before → after | generated MB/s before → after | allocations/token after, runtime / generated |
|---|---|---:|---:|---:|
| auto | interpreter | 1.739 → 1.856 | 1.645 → 1.815 | 4.200 / 4.210 |
| auto | YJIT | 4.967 → 5.210 | 2.977 → 3.184 | 4.200 / 4.210 |
| auto | ZJIT | 1.301 → 2.119 | 0.373 → 0.441 | 4.200 / 4.210 |
| strscan | interpreter | 1.767 → 1.973 | 0.785 → 1.090 | 4.200 / 4.610 |
| strscan | YJIT | 4.983 → 5.182 | 1.224 → 1.633 | 4.200 / 4.610 |
| strscan | ZJIT | 2.029 → 1.838 | 0.875 → 0.791 | 4.200 / 4.610 |

The default mode's change removes temporary ranges when extracting text and
location spans. Its allocations fell from 5.200 / 5.210. Explicit StringScanner
mode also uses proven whole-token scans; its generated allocations fell from
6.210 to 4.610. This does not meet the 4.0 or 3.4 allocation targets. Whole-token
scanning remains explicit because the ZJIT sample regressed; these samples do
not establish a universal speedup or a release performance qualification.

Reproduce the default sample with:

```sh
ruby -Ilib benchmark/run.rb --iterations 5 --json
ruby --yjit -Ilib benchmark/run.rb --iterations 5 --json
ruby --zjit -Ilib benchmark/run.rb --iterations 5 --json
```

To measure explicit StringScanner mode without changing the maintained example:

```sh
mkdir -p tmp/whole-token/examples/json
ruby -e 'source = File.read("examples/json/lexer.flexr.rb"); File.write("tmp/whole-token/examples/json/lexer.flexr.rb", source.sub("backend :direct", "backend :direct\n    accel :strscan"))'
ruby -Ilib benchmark/run.rb --spec tmp/whole-token/examples/json/lexer.flexr.rb --iterations 5 --json
```

Repeat the last command with `--yjit` or `--zjit` immediately after `ruby`.

### JSON punctuation with `emit:`

Replacing the JSON example's six punctuation action blocks with the existing
`emit:` option preserved token types and values across runtime, generated,
standalone, String, and one-byte IO input, including Unicode and escaped quotes.
The same Ruby 4.0.9 host, default corpus, and five warmup plus five measured
iterations produced this interpreter sample after the range-allocation change:

| mode | MB/s before → after | allocations/token before → after | handwritten ratio before → after |
|---|---:|---:|---:|
| runtime | 1.863 → 1.928 | 4.200 → 3.600 | 0.221x → 0.249x |
| generated | 1.794 → 1.963 | 4.210 → 3.610 | 0.213x → 0.254x |

The 4.0 allocations/token target is met for this JSON example; 3.4 and the 0.35x
throughput target remain unmet. This sample does not establish results for
other lexers or JIT engines. Conversion actions for strings, numbers, booleans,
and null remain blocks.

The JSON golden digest and regression baseline's source fingerprint were
updated for the equivalent shorthand specification. Input identity, captured
baseline metrics, ratio thresholds, and the 0.18x performance floor were kept.
Use the default benchmark commands above to reproduce the new example.
