# Performance log

## DFA stretch experiments (2026-11-22)

Run `ruby benchmark/dfa_stretch.rb` to reproduce the results below. The probe
walks compiled flexr DFA rows and checks them against lexer and recognizer
results. It uses fixed ASCII fixtures and adds no scanner options or backends.
Ruby 4.0.9 and 3.4.9 produced the same results on arm64-darwin25.

### Shortest match

For `aaa!`, the earliest accept is `SINGLE` at byte 1. The latest is `RUN`
at byte 3, and the lexer emits `[:RUN, "aaa"]`. A separate grammar declaring
`/a+/` before `"a"` also has an accept at byte 1, but flexr's `firstmatch`
backend takes Ruby's `"aaa"` match for `/a+/`. OCamllex describes `shortest`
as choosing the shortest matching prefix.
[OCaml 5.4 reference manual, section 17.2.3](https://ocaml.org/manual/5.4/ocaml-5.4-refman.pdf)

An early exit from the DFA can select the shortest eligible prefix when the
body length is the ranking length. Trailing context makes that distinction
observable. On `abcd`, `"a"` followed by `"bcd"` ends its body at byte 1 and its
context at byte 4. The competing `"ab"` ends at byte 2. The current recognizer
chooses `"a"` because its full match is longer. A shortest policy must specify
whether this example compares 1 to 2 or 4 to 2. Before exposing an option,
agree on scope and on that ordering, then check UTF-8 and anchor eligibility,
parser expectations, and priority ties across runtime, generated, and
standalone scanners. Trace and diagnostic witnesses would need the same policy.

### REJECT

The compiled history for `aaa!`, in retry order, is `RUN@3`, `PAIR@2`,
`RUN@2`, `SINGLE@1`, `RUN@1`. `PAIR` has higher priority than `RUN` at byte 2.
This history includes both the lower-ranked rule at the same endpoint and the
same rule at shorter endpoints. Keeping just the losing rules at the winning
byte or a single match per rule would discard candidates. Recording every
acceptance took 2, 10, 66, and 1,026 entries for 1, 8, 64, and 1,024 `a` bytes.
Flex describes `yyreject()` as continuing directly to the next-ranked choice
after the effects of the preceding action have occurred.
[Flex manual, Actions](https://westes.github.io/flex/manual/Actions.html)

In the probe, the first action appends `[:run, "aaa"]` to an array and switches
the scanner to `:inside` at byte 3. Checkpoint restoration returns the scanner
to `:initial` at byte 0. The parser filter selects `[:PAIR, "aa"]` on the next
call, and the array still holds the original entry. The filter lets a parser
choose token kinds before any action runs, so it cannot select a shorter
`RUN` after `RUN`'s action. A REJECT API would need an explicit action contract
for emissions, state transitions, input changes, and effects already visible
to callers. It would also need bounded retry work and streaming retention.
The probe leaves REJECT at the feasibility stage until that contract exists.

### Tagged captures

`/(?<head>a|aa)(?<tail>a+)/` and `/(?<head>aa|a)(?<tail>a+)/` compile to identical
three-state DFAs. The probe checks every state/byte transition and acceptance.
For `aaa!`, both recognize a three-byte body with the same rule and pattern
indices. Ruby replay gives `head = "a", tail = "aa"` for the first and
`head = "aa", tail = "a"` for the second. The respective boundaries are
`[0, 1), [1, 3)` and `[0, 2), [2, 3)`.

The bounded model runs two compiled lanes, `/aa+/` and `/aaa+/`, in one pass.
It retains the two active states and the split/end offsets of the last accept.
The alternative order selects the split if both lanes accept. The model agreed
with recognition and capture replay on 126 matching cases and six cases with
no match. It handles this fixed-width-head example. A general TDFA needs tag
updates and a way to distinguish and choose competing subgroup paths. re2c
provides separate leftmost-greedy and POSIX policies.
[re2c manual, Submatch extraction](https://re2c.org/manual/manual_c.html#submatch-extraction)

Keep lazy replay as described in the [capture replay implementation record](implementations/20261122_replay_named_regexp_captures.md).
Before replacing it, compare subgroup values and byte ranges against Ruby for
ambiguous alternatives, empty and optional groups, repetitions, and Unicode.
Then check trailing context, streaming, delegation, and generated artifacts.
Measure state growth, code size, and capture throughput under the supported
Ruby engines. This small model establishes how to preserve the split in one
case. Throughput remains an open question for a general TDFA.

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

### Fixed workload matrix

Use `--workloads` to run the same corpus bytes as frozen and mutable strings
for JSON, TOML, GraphQL, SQL, and the Ruby subset. Each result records the
specification and input hashes, the input mode, and the measured Ruby engine.
Before reporting a cell, the harness compares complete tokens from runtime,
generated, and standalone scanners. The standalone check runs in a separate
Ruby process. Parity checks run outside the timed scans.

```sh
ruby -Ilib benchmark/matrix.rb --workloads --iterations 10
FLEXR_BENCHMARK_CHECK_MATRIX=1 ruby -Ilib benchmark/matrix.rb --workloads --iterations 10
```

The gate takes the median of three generated/runtime samples for every cell.
A ratio below `1.0` or an unavailable engine fails the check and identifies
its workload, input mode, and engine in the JSON report. Run this gate on
the reference machine. For a single custom input, pass `--input-mode frozen`
or `--input-mode mutable` to select the String mode explicitly.

### Scan phase profiling

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
threshold. The [measured performance floor record](implementations/20260810_measured_performance_floor.md) explains the target revision.

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

## 2026-11-22: generated frozen-input scan

The generated simple scanner now follows the runtime's DFA path for frozen
strings with the default `accel :auto` and no active scan guards. It reads
the region cache and token-limit parameters only when it needs the fallback
path. A warmed diagnostic run on `0d1cc81` reported 8,748,740 megamorphic
instance-variable reads and 1,699,605 writes across five generated scans of
the JSON corpus with YJIT statistics enabled. Both counters reached zero
when the acceleration cache fields were initialized up front in an
experiment. The DFA path avoids those lazy cache writes on eligible input.

The comparison below uses Ruby 4.0.9 on arm64-darwin25 and the default
140,000-byte JSON input with 50,000 emitted tokens. Baseline `0d1cc81` and
the updated scanner were run in alternating order. Each result is the median
of three runs with ten warmup and ten timed iterations per engine. Ratios
are calculated per run before taking the median.

| Engine | Generated MB/s before → after | Generated / runtime before → after | Generated / handwritten before → after |
|---|---:|---:|---:|
| Interpreter | 1.874 → 1.964 | 0.992x → 1.036x | 0.223x → 0.234x |
| YJIT | 3.635 → 5.633 | 0.606x → 0.958x | 0.388x → 0.519x |
| ZJIT | 0.431 → 2.080 | 0.200x → 0.972x | 0.043x → 0.202x |

YJIT generated throughput reaches the 0.50x handwritten target in this sample.
Both JITs remain below the 1.0x generated/runtime target. Runtime allocations
stay at 3.600 per token, and generated allocations move from 3.210 to 3.200.
A separate check compared the full runtime, generated, and standalone token
sequences for frozen JSON, TOML, GraphQL, SQL, and Ruby subset inputs in all
three engines.

Run the reference JSON matrix with:

```sh
ruby -Ilib benchmark/matrix.rb --iterations 10
```

The other lexer samples use one run with five warmup and five timed
iterations per engine on the same machine. The values are generated/runtime
throughput ratios. TOML, GraphQL, and SQL use the frozen built-in inputs.
Ruby subset uses the mutable string loaded by `--input-file`.

| Lexer | Interpreter before → after | YJIT before → after | ZJIT before → after |
|---|---:|---:|---:|
| TOML | 0.631x → 0.647x | 0.291x → 0.424x | 0.188x → 0.626x |
| GraphQL | 0.725x → 0.722x | 0.319x → 0.496x | 0.388x → 0.683x |
| SQL | 0.643x → 0.681x | 0.350x → 0.467x | 0.409x → 0.664x |
| Ruby subset | 0.845x → 0.849x | 0.419x → 0.404x | 0.244x → 0.243x |

Run these workloads with:

```sh
for lexer in toml graphql sql; do
  ruby -Ilib benchmark/matrix.rb --spec "examples/$lexer/lexer.flexr.rb" --iterations 5
done
ruby -e 'STDOUT.write(%q(class Foo "ok" end ) * 10_000)' > /tmp/flexr-ruby-subset-input.txt
ruby -Ilib benchmark/matrix.rb --spec examples/ruby_subset/lexer.flexr.rb \
  --input-file /tmp/flexr-ruby-subset-input.txt --iterations 5
```

## 2026-11-22: packed lookup and token-loop allocations

The packed transition lookup and `next_token` use condition-controlled loops,
avoiding the block allocation on each packed lookup or token call. The token
loop still returns the result of an exhausted action enumerator. Packed rows
remain lazy. A warmed check exercises inherited transitions and confirms that
reading them leaves the dense rows unmaterialized. The generated direct fast
path keeps its negative transition sentinel as an integer until the scan
loop exits.

The JSON comparison uses Ruby 4.0.9 on arm64-darwin25 and the same 140,000-byte,
50,000-token input as the previous sample. Baseline `73a6587` and the updated
loops ran in alternating order. Each result is the median of three runs with
ten warmup and ten timed iterations per engine.

| Engine | Runtime MB/s before → after | Generated MB/s before → after | Generated / runtime before → after | Generated / handwritten before → after |
|---|---:|---:|---:|---:|
| Interpreter | 1.897 → 2.022 | 1.978 → 2.199 | 1.043x → 1.088x | 0.237x → 0.282x |
| YJIT | 6.033 → 6.482 | 5.720 → 6.743 | 0.948x → 1.012x | 0.523x → 0.728x |
| ZJIT | 2.092 → 2.342 | 2.083 → 2.388 | 0.994x → 1.010x | 0.206x → 0.269x |

Runtime allocations fell from 3.600 to 2.600 per token on all three engines,
below the 3.4 target. Generated allocations fell from 3.200 to 2.200.
The YJIT sample reached the 0.70x handwritten stretch target. The three paired
runs reached the 1.0x generated/runtime target on all three engines, with
ZJIT ratios from 1.007x to 1.024x. A separate single run through
`rake bench:matrix` measured 0.980x on YJIT and 0.984x on ZJIT. This
variation leaves the 1.0x ratio as a measurement target.

The full frozen JSON, TOML, GraphQL, SQL, and Ruby subset token sequences
matched across runtime, generated, and standalone on all three engines.
Use the matrix commands in the previous section to repeat the timings.

The non-JSON runs used five warmup and five measured iterations per engine.
The allocation counts were identical across engines. Ruby subset timing
uses the mutable input-file control from the previous section.

| Lexer | Generated allocations/token before → after | Interpreter generated/runtime | YJIT generated/runtime | ZJIT generated/runtime |
|---|---:|---:|---:|---:|
| TOML | 10.334 → 2.000 | 0.610x → 0.775x | 0.413x → 0.589x | 0.621x → 0.837x |
| GraphQL | 7.333 → 2.000 | 0.722x → 0.844x | 0.506x → 0.652x | 0.674x → 0.878x |
| SQL | 9.889 → 2.667 | 0.703x → 0.836x | 0.447x → 0.570x | 0.639x → 0.854x |
| Ruby subset | 14.778 → 7.009 | 0.824x → 0.952x | 0.416x → 0.414x | 0.243x → 0.250x |

## 2026-11-22: frozen scan EOF check

The unguarded generated DFA loop uses the end-of-input result from
`String#getbyte` to stop scanning. This removes a separate size lookup and
comparison per byte. A zero byte still participates in the DFA.

The paired runs use Ruby 4.0.9 on arm64-darwin25 and the same reference
JSON input as the previous entry. Run
`ruby -Ilib benchmark/matrix.rb --iterations 10` three times per revision,
alternating baseline `76c13b4` and the updated scanner. Each run warms each
engine with ten scans before timing ten more.

| Engine | Generated MB/s before → after | Median generated/runtime before → after | Generated/runtime range after |
|---|---:|---:|---:|
| Interpreter | 2.182 → 2.247 | 1.077x → 1.104x | 1.084x–1.108x |
| YJIT | 6.828 → 6.803 | 1.030x → 1.059x | 1.026x–1.089x |
| ZJIT | 2.392 → 2.409 | 1.019x → 1.020x | 1.015x–1.027x |

Runtime stayed at 2.600 allocations per token and generated stayed at 2.200.
The ZJIT sample clears the 1.0x target with about two percent headroom on
this machine. The YJIT generated rate was nearly unchanged despite
variation in the ratio.

A separate experiment saved each accepting state in locals and filled the
reused match record once after the longest match was known. The
generated/runtime medians moved from 1.097x to 1.097x for the interpreter,
1.037x to 0.978x for YJIT, and 1.006x to 0.992x for ZJIT. The scanner
continues to update the match record during traversal.

## 2026-11-22: whole-token selection by engine and workload

This experiment compares whole-token `StringScanner` plans with the frozen
DFA path on Ruby 4.0.9, arm64-darwin25. The runtime uses the same lexer with
`accel :strscan`. Generated measurements include both the complete explicit
`:strscan` mode and a control that keeps the explicit artifact's whole-token
plans but sets the instance's `@accel_mode` to `:auto`. The control keeps the
DFA fallback so its ratio isolates the native whole-token attempt from the
per-region fallback.

Each engine and workload runs in its own process. The test compares all
token kinds and values before warming up each variant. The reference JSON
workload uses ten warmup and ten timed scans per sample. The rest use six
of each. Three samples rotate the order of the variants. The Ruby subset
input repeats `class Foo "ok" end ` 10,000 times and is frozen for this
experiment. The two synthetic JSON inputs repeat 680 JSON objects, with
192 spaces after each object or 192 ASCII letters in each string value.
The complete token sequences matched across all variants and engines.

Values are throughput relative to the corresponding runtime or generated
DFA baseline. Each cell lists interpreter, YJIT, and ZJIT in that order.

| Workload | Bytes | Runtime explicit | Generated explicit | Generated whole-token only |
|---|---:|---:|---:|---:|
| JSON | 140,000 | 1.056x / 0.776x / 0.992x | 0.520x / 0.279x / 0.550x | 1.027x / 0.663x / 1.008x |
| JSON with long space runs | 140,080 | 3.906x / 2.528x / 4.052x | 1.818x / 0.851x / 1.927x | 3.571x / 1.744x / 3.546x |
| JSON with long strings | 139,400 | 1.002x / 0.850x / 0.992x | 0.830x / 0.284x / 0.914x | 0.978x / 0.789x / 0.975x |
| TOML | 160,000 | 1.008x / 0.688x / 0.946x | 0.506x / 0.286x / 0.544x | 1.138x / 0.764x / 1.132x |
| GraphQL | 320,000 | 1.217x / 0.743x / 1.099x | 1.577x / 1.092x / 1.546x | 1.570x / 1.063x / 1.545x |
| SQL | 390,000 | 1.026x / 0.758x / 0.947x | 0.700x / 0.439x / 0.306x | 1.153x / 0.714x / 0.934x |
| Ruby subset | 190,000 | 1.033x / 0.780x / 0.974x | 0.656x / 0.425x / 0.313x | 1.179x / 0.782x / 1.017x |

The whole-token attempt paid off on long whitespace runs but slowed the
similarly sized long-string workload. GraphQL gained in generated mode
while runtime mode slowed on YJIT. These results leave whole-token
scanning on explicit `accel :strscan`. A default needs a cheap way to
recognize profitable matches and measurements that include the cost of
that choice and its fallback.

## 2026-11-22: select the frozen scan's transition layout at generation

The generated artifact already determines whether its state transitions use
flat direct tables. Selecting the lookup when generating the loop removes
that choice from each byte scanned on the frozen, unguarded path.

On the integrated branch, the EOF change alone measured a ZJIT ratio of
0.992x with ten iterations. Adding packed-table lookups to the same loop
lowered YJIT throughput on the reference direct lexer.

Run `FLEXR_BENCHMARK_CHECK_MATRIX=1 FLEXR_BENCHMARK_ITERATIONS=15 bundle exec rake bench:matrix`
with Ruby 4.0.9 on arm64-darwin25 and the same 140,000-byte JSON input.
The medians of three fresh processes passed on all engines.

| Engine | Generated/runtime samples | Median | Generated/handwritten at the median |
|---|---:|---:|---:|
| Interpreter | 1.093x, 1.198x, 1.101x | 1.101x | 0.279x |
| YJIT | 1.009x, 1.017x, 0.982x | 1.009x | 0.686x |
| ZJIT | 1.014x, 1.007x, 1.032x | 1.014x | 0.262x |

Runtime remained at 2.600 allocations per emitted token. Both JIT ratios have
limited headroom, and the interpreter remains below the 0.30x target.

## 2026-11-22: cache the direct scan layout per DFA

The generated direct scanner gathers the start state, transition table,
byte classes, acceptances, and rule array in its existing per-DFA cache.
The scanner reuses that layout when it returns to a lexical state.
The simple scan reads the cached layout instead of repeating the DFA
lookups for every token.

The comparison uses Ruby 4.0.9 on arm64-darwin25 and the 140,000-byte
reference JSON workload, which emits 50,000 tokens. Baseline `e6dd953`
and the updated scanner ran in alternating order. Each row reports medians
from three runs with ten warmup and ten timed scans per engine.

| Engine | Generated MB/s before → after | Generated/runtime before → after | Generated/handwritten before → after |
|---|---:|---:|---:|
| Interpreter | 2.265 → 2.422 | 1.115x → 1.184x | 0.286x → 0.315x |
| YJIT | 7.424 → 8.149 | 1.144x → 1.198x | 0.753x → 0.868x |
| ZJIT | 2.453 → 2.524 | 1.042x → 1.084x | 0.271x → 0.270x |

The separate reference run used the same gate as the previous comparison.

```sh
FLEXR_BENCHMARK_CHECK_MATRIX=1 FLEXR_BENCHMARK_ITERATIONS=15 bundle exec rake bench:matrix
```

| Engine | Generated/runtime samples | Median | Generated/handwritten at the median |
|---|---:|---:|---:|
| Interpreter | 1.177x, 1.180x, 1.165x | 1.177x | 0.307x |
| YJIT | 1.062x, 1.064x, 1.073x | 1.064x | 0.763x |
| ZJIT | 1.034x, 1.068x, 1.060x | 1.060x | 0.274x |

The interpreter crossed the 0.30x handwritten target in the reference
run and all three paired samples. The reference matrix passed on all
three engines. Runtime and generated allocations stayed at 2.600 and
2.200 per emitted token.

A separate interpreter screening run tested a preselected winning rule,
early exit from a terminal accepting state, and their combination.
The baseline measured 2.300 MB/s generated. The three variants measured
2.304, 2.308, and 2.303 MB/s, respectively.

A one-rule direct standalone sample measured 99,698 bytes before and
99,760 bytes after. The ordinary standalone size checks passed for LF and
CRLF source files.

TOML, GraphQL, and SQL were also measured on temporary copies with
`backend :direct`. The table reports generated MB/s before and after the
change. Each measurement used five warmup and five timed scans.

| Workload | Interpreter | YJIT | ZJIT |
|---|---:|---:|---:|
| TOML | 2.701 → 2.924 | 8.418 → 9.561 | 2.890 → 2.982 |
| GraphQL | 1.655 → 1.791 | 5.244 → 5.899 | 1.784 → 1.871 |
| SQL | 2.190 → 2.372 | 6.351 → 6.634 | 2.295 → 2.335 |

SQL on ZJIT is the median of three follow-up runs with seven warmup and
seven timed scans, alternating the two revisions. The initial pair
slowed both runtime and generated scanners in the candidate process.
In the follow-up, the generated/runtime medians were 1.024x and 1.035x.

Runtime, generated, and standalone produced identical frozen-input
token sequences on all three engines for the five stock workloads
and the three direct variants.

## 2026-11-23: Frozen and mutable workload baseline

Ruby 4.0.9 on arm64-darwin25 measured the scanners from `f718499` using the
fixed workload matrix. Each cell is the median of three samples, each with
three warmup and three timed scans. The values show generated/runtime
throughput for frozen input followed by mutable input. All 30 cells matched
complete tokens across runtime, generated, and standalone lexers.

| Workload | Interpreter | YJIT | ZJIT |
|---|---:|---:|---:|
| json | 1.219x / 1.144x | 1.230x / 0.587x | 1.119x / 0.238x |
| toml | 0.797x / 0.918x | 0.592x / 0.426x | 0.867x / 0.241x |
| graphql | 0.872x / 0.960x | 0.654x / 0.454x | 0.904x / 0.278x |
| sql | 0.844x / 0.932x | 0.647x / 0.415x | 0.886x / 0.246x |
| ruby_subset | 0.841x / 0.944x | 0.672x / 0.442x | 0.903x / 0.252x |

The `1.0x` gate passed in 4 of 30 cells. The lowest ratio was
`0.238x`. Use this matrix to locate slow workloads and compare changes on
the same machine.

```sh
FLEXR_BENCHMARK_CHECK_MATRIX=1 ruby -Ilib benchmark/matrix.rb --workloads --iterations 3
```

## 2026-11-23: Snapshot mutable String input

The same Ruby 4.0.9 machine and fixed workload matrix compared mutable
inputs before and after taking one frozen snapshot per lexer. Each cell
is the median of three samples with three warmup and three timed scans per
sample. Runtime, generated, and standalone token parity passed in all 30
cells, including frozen inputs. This table shows the generated/runtime
ratios for inputs supplied as mutable Strings.

| Workload | Interpreter | YJIT | ZJIT |
|---|---:|---:|---:|
| json | 1.144x to 1.215x | 0.587x to 1.221x | 0.238x to 1.109x |
| toml | 0.918x to 0.810x | 0.426x to 0.592x | 0.241x to 0.871x |
| graphql | 0.960x to 0.874x | 0.454x to 0.665x | 0.278x to 0.918x |
| sql | 0.932x to 0.849x | 0.415x to 0.652x | 0.246x to 0.883x |
| ruby_subset | 0.944x to 0.842x | 0.442x to 0.659x | 0.252x to 0.902x |

All six JSON cells met the `1.0x` threshold. Across the full matrix the
lowest ratio was `0.592x`. The other four workloads still need
attention before the gate can pass.

## 2026-11-23: Reuse failed longest-match continuations

For rules `/a/` and `/a*b/` on a frozen string of `a` bytes, Ruby 4.0.9 on
arm64-darwin25 returned the expected single-byte tokens at each input size.
Times include collecting every token, with compilation outside the timed
region. Each value is the median of three runs.

| Input bytes | Seconds |
| ---: | ---: |
| 125,000 | 0.206 |
| 250,000 | 0.394 |
| 500,000 | 0.813 |
| 1,000,000 | 1.663 |

The five workload specifications were also measured against the combined
backup-analysis and snapshot baseline (`a31b39f`). Three alternating
baseline and candidate pairs per condition used three warmup and three
timed scans. Each column shows the lowest median candidate-to-baseline
throughput ratio across frozen and mutable inputs and the interpreter,
YJIT, and ZJIT.

| Workload | Runtime | Generated |
| --- | ---: | ---: |
| JSON | 1.0207x | 1.0065x |
| TOML | 1.0190x | 1.1390x |
| GraphQL | 0.9967x | 1.1093x |
| SQL | 1.0439x | 1.1245x |
| Ruby subset | 1.0452x | 1.1013x |

Every condition was within the 1% regression threshold. The workload
matrix separately confirmed typed token parity across runtime, generated,
and standalone scanners in all 30 conditions.
