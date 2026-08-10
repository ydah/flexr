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
| runtime | 0.449 | 160,490 | 41.6 | 0.084x |
| generated | 0.415 | 148,384 | 44.4 | 0.077x |
| handwritten | 5.374 | 1,919,116 | 3.4 | 1.000x |
