# Benchmark corpora

The 10MB JSON corpus is deterministic and generated on demand so the repository
does not need to carry a large derived blob:

```sh
ruby benchmark/corpora/generate_json.rb > benchmark/corpora/json_10mb.json
```

The default size is exactly 10,000,000 bytes. Set `FLEXR_JSON_BYTES` to produce
a different deterministic size for local experiments.
