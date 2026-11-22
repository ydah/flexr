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
## Lrama standalone recognizer experiment (2026-11-20)

At flexr revision `80b5d13`, `benchmark/lrama_lexer.rb` built a standalone
grammar-token recognizer and adapted Lrama's lexer to use it for normal
grammar tokens. It retained Lrama's trivia, C-code scanning, identifier
lookahead, token classes, locations, and parser. The adapter deliberately uses private scanner positions; this
is an experiment, not a supported Lrama integration or a production replacement.

```sh
git clone https://github.com/ruby/lrama.git /tmp/lrama
git -C /tmp/lrama checkout 22de9d99f6402290a637627f3516a1a2db6c9aab
bundle exec ruby benchmark/lrama_lexer.rb /tmp/lrama
```

The pinned upstream revision's 78 grammar fixtures produced identical token
kinds, values, locations, and parser errors: 77 parsed successfully, and 3,767
tokens were compared. Both paths include the same parser and event collection.
On Ruby 4.0.9, arm64-darwin25, three corpus passes took 0.0434 seconds with
Lrama's scanner and 11.9124 seconds with the standalone recognizer adapter.
These short local timings are illustrative, not a statistical benchmark.

The standalone experiment stopped at local benchmarking. The embedded
recognizer experiment below revisits the adapter overhead.

## Lrama embedded recognizer experiment (2026-11-22)

The benchmark uses Flexr's `Recognizer#match` with the original grammar text
and the current byte offset. The embedded lexer recognizes symbols, integers,
and identifiers. The pinned Lrama scanner checks `%{`, `%}`, and `%%` before
directives. Integers and identifiers start with different bytes from the
other token kinds. Lrama handles quoted tokens, tags, directives, trivia,
identifier lookahead, and C declarations. The subclass reads Lrama's
scanner and advances it through `StringScanner#pos=`.

On Lrama revision `22de9d99f6402290a637627f3516a1a2db6c9aab`, the complete
token classes, kinds, values, source locations, and parser errors matched
across 78 fixtures. Both lexers successfully parsed 77 fixtures. Flexr
recognized 2,618 of 3,767 tokens (69.5 percent), including 1,539 symbols,
1,067 identifiers, and 12 integers.

Each measurement uses Ruby 4.0.9 on arm64-darwin25 and the same 78 inputs.
The harness checks token parity before timing, then runs three warmup and
30 measured passes per lexer. It uses the same Lrama parser in both modes
and swaps the lexer class outside the timed passes. The table reports
medians from three processes per engine, with the ratio calculated per sample.

| Engine | Native seconds | Embedded seconds | Embedded / native runtime |
|---|---:|---:|---:|
| Interpreter | 0.3712 | 0.4425 | 1.195x |
| YJIT | 0.2872 | 0.2949 | 1.026x |
| ZJIT | 0.3750 | 0.3870 | 1.047x |

All nine samples met the 2.0x target for complete parser passes.
Use the same pinned Lrama checkout as in the previous experiment.

```sh
for engine in --disable=yjit,zjit --yjit --zjit; do
  bundle exec ruby "$engine" -Ilib -r ./benchmark/lrama_lexer \
    -e 'Flexr::Benchmarking::LramaLexer.run(ARGV.fetch(0), iterations: 30)' /tmp/lrama
done
```

## Lexer throughput benchmarks

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


## 2026-11-21: combined v2 readiness sample

The integration checkout at `f9c629c` combines the v2 Data records and generated
method actions with whole-token scanning support and the JSON `emit:` shorthand.
Ruby 4.0.9 on arm64-darwin-25, without a JIT, processed the default 140,000-byte
JSON corpus with 50,000 emitted tokens. Five warmup and five measured iterations
ran after the test and browser checks finished.

| mode | MB/s | allocations/token | throughput relative to handwritten |
|---|---:|---:|---:|
| runtime | 1.906 | 3.600 | 0.235x |
| generated | 1.933 | 3.210 | 0.238x |
| handwritten | 8.118 | 3.400 | 1.000x |

Both flexr modes meet the 4.0 allocations/token target for this corpus. The
3.4 target is met by generated mode; runtime remains above it. Neither mode
meets the 0.35x handwritten throughput target. This local readiness sample is
not a release performance qualification and does not establish results for
other lexers or JIT engines.

`rake bench:regression` also passed with the existing baseline metrics, identity,
ratio thresholds, and 0.18x floor unchanged. Reproduce the five-iteration sample
with `ruby -Ilib benchmark/run.rb --iterations 5 --json`.
