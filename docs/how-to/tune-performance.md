# Tune performance

Measure a representative input before changing the backend:

```sh
ruby -Ilib benchmark/run.rb --spec examples/json/lexer.flexr.rb
bundle exec rake bench:regression
```

Use `token_kind :yield` when the consumer streams tokens and does not need an
intermediate token array. Use generated mode to move DFA construction out of
application startup. `backend :auto` chooses `:direct` for large transition
tables and `:table` otherwise; `:table` and `:direct` preserve the same
longest-match semantics.

Acceleration is an optimization over the DFA, not a second matcher. `accel
:auto` selects an available safe path, while `:strscan`, `:regexp`, and `:none`
make the choice explicit. Trailing context disables region acceleration for the
affected rule and emits `FLEXR-W012` unless acceleration is disabled.

The [performance log](../perf-log.md) records reproducible local observations,
and the [backend explanation](../explanation/backends.md) describes the memory
and compatibility trade-offs.
