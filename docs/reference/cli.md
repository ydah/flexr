# CLI reference

The executable is `flexr`, with usage:

```text
flexr [COMMAND] SPEC.rb [options]
```

Without a command, `flexr SPEC.rb` generates Ruby. `SPEC.rb` is normally a
`.flexr.rb` file, except for `import`, which accepts flex `.l` and Rexical
`.rex` input.

## Commands

| Command | Purpose | Main output |
|---|---|---|
| `check SPEC` | Compile and render diagnostics | Human or JSON diagnostics |
| `stats SPEC` | Report DFA states, byte classes, and table sizes | JSON |
| `tokens SPEC` | Print names declared by `emits` | Space-separated names |
| `dot SPEC` | Render the DFA as Graphviz DOT | DOT on stdout |
| `trace SPEC` | Print DFA states, accepts, and transitions | Text on stdout |
| `explain SPEC` | List parsed rules and patterns | Text on stdout |
| `bench SPEC` | Run the benchmark harness | Benchmark output |
| `import INPUT` | Translate flex/Rexical input | Ruby on stdout or `--output` |

`trace` describes the automaton; it does not trace a particular input string.
`dot` marks accepting states and accelerated regions for visual inspection.

## Options

| Option | Values / argument | Applies to |
|---|---|---|
| `-o, --output PATH` | File path | Generation and import |
| `-b, --backend NAME` | `table`, `direct`, `firstmatch`, `auto` | Compilation |
| `--token-kind KIND` | `array`, `struct`, `yield` | Generated/runtime contract |
| `--accel MODE` | `auto`, `strscan`, `regexp`, `none` | Runtime optimization |
| `--standalone` | Flag | Generation |
| `--eval` | Flag | Generation and check |
| `--table-compression VALUE` | `none`, `rows`, `full` | Generation |
| `--table-format VALUE` | `literal`, `packed` | Generation |
| `--max-dfa-states N` | Positive integer | Compilation |
| `-W, --warn LEVEL` | `all`, `default`, `none` | Check |
| `--warn-as-error` | Flag | Check and generation |
| `--color WHEN` | `auto`, `always`, `never` | Human diagnostics |
| `--format FMT` | `human`, `json` | Check and stats |
| `--rule N` | Non-negative integer | Explain |

The complete help output is kept as a checked snapshot:

<!-- flexr-help:start -->
Usage: flexr [COMMAND] SPEC.rb [options]

Commands: check, stats, tokens, dot, explain, trace, bench, import
Options:
  -o, --output PATH          generated output path
  -b, --backend NAME         table | direct | firstmatch | auto
      --token-kind KIND      array | struct | yield
      --accel MODE            auto | strscan | regexp | none
      --standalone
      --eval
      --table-compression VALUE  none | rows | full
      --table-format VALUE       literal | packed
      --max-dfa-states N
  -W, --warn LEVEL           all | default | none
      --warn-as-error
      --color WHEN            auto | always | never
      --format FMT            human | json
<!-- flexr-help:end -->

## Exit statuses

| Status | Meaning |
|---:|---|
| `0` | Command completed; warnings do not fail by default |
| `1` | Specification, input, import, or generation failure |
| `2` | Invalid command-line usage |

`check --format json` writes one JSON array to stdout. Human diagnostics go to
stdout for `check` and errors go to stderr for command failures. Use
`--warn-as-error` when a warning should fail CI.
