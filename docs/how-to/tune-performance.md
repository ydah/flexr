# Tune performance

Measure a representative input before changing the backend:

```sh
ruby -Ilib benchmark/run.rb --spec examples/json/lexer.flexr.rb
bundle exec rake bench:regression
```

Use `token_kind :yield` when the consumer streams tokens and does not need an
intermediate token array. Use generated mode to move DFA construction out of
application startup. `backend :auto` compares dense memory, packed memory, and
lookup costs rather than using a fixed table-size threshold; `:table` and
`:direct` preserve the same longest-match semantics.

Use `emit:` for tokens whose value is the unchanged matched text. For example,
`rule(/:/, emit: :COLON)` avoids invoking an action block for every separator.
Keep blocks for value conversions and state transitions. The JSON example
uses this form for punctuation.

Acceleration is an optimization over the DFA, not a second matcher. `accel
:auto` selects an available safe path, while `:strscan`, `:regexp`, and `:none`
make the choice explicit. Trailing context disables region acceleration for the
affected rule and emits `FLEXR-W012` unless acceleration is disabled.

Explicit `accel :strscan` can also scan a complete token in one native call
when a conservative DFA check proves it safe. This path needs frozen String
input with retained bytes and no active scanning or token-size guard. Streaming
and mutable input, anchors, trailing context, and unproven patterns keep the DFA
path. Measure with your actual token lengths and Ruby/JIT configuration before
choosing `:strscan`; `:auto` keeps its region-selection policy.

The [performance log](../perf-log.md) records reproducible local observations,
and the [backend explanation](../explanation/backends.md) describes the memory
and compatibility trade-offs.
