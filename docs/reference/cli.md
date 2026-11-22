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
| `trace SPEC` | Print DFA states, or trace input when supplied | Human or JSON input trace |
| `skeleton SPEC` | Build shortest inputs that cover DFA transitions | Human or JSON coverage report |
| `explain SPEC` | List parsed rules and patterns | Text on stdout |
| `bench SPEC` | Run the benchmark harness | Benchmark output |
| `import INPUT` | Translate flex/Rexical input | Ruby on stdout or `--output` |

`trace` without input describes the automaton. To execute a specification and
inspect rule selection, pass `--input STRING` or `--input-file PATH`.
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
| `-W, --warn LEVEL` | `all`, `default`, `none` | Check and generation |
| `--warn-as-error` | Flag | Check and generation |
| `--color WHEN` | `auto`, `always`, `never` | Human diagnostics |
| `--format FMT` | `human`, `json`, `lrama` | `lrama` is for tokens only |
| `--grammar PATH` | Grammar path | Compare `%token` names with `emits` during check |
| `--target 2.0` | none | Static check migration requirements and structured-token declarations |
| `--rule N` | Non-negative integer | Explain |
| `--input STRING` | Literal input, including an empty string | Trace |
| `--input-file PATH` | Input file | Trace and bench |
| `--generated` | Run the generated scanner | Input trace |
| `--verify` | Execute the generated cases in all three modes | Skeleton |

The complete help output is kept as a checked snapshot:

<!-- flexr-help:start -->
Usage: flexr [COMMAND] SPEC.rb [options]

Commands: check, stats, tokens, dot, explain, trace, skeleton, bench, import
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
      --format FMT            human | json | lrama (tokens only)
      --grammar PATH          compare emits with grammar %token declarations (check only)
      --input STRING          trace input (executes SPEC actions)
      --input-file PATH       trace or benchmark input
      --generated             trace generated scanner
      --verify                verify skeleton across all modes (executes SPEC actions)
      --target 2.0            report migration requirements (static check only)
<!-- flexr-help:end -->

## Input trace

```sh
flexr trace lexer.flexr.rb --input 'if == total'
flexr trace lexer.flexr.rb --input-file input.txt --generated --format json
```

Input tracing executes the specification's Ruby code and actions. Use trusted
specifications, as with running a lexer normally. Actions run once, including
actions that skip input or change state. `--generated` generates and evaluates
the scanner in memory; it does not write an output file.

Each step reports byte offsets, matched text, the lexical state before and
after the action, candidate rule numbers and lengths, the selected rule, and
the action result (`emit` or `skip`). Human candidate lengths use
`body/total`, with trailing context included only in the total. `rule_order`
means several candidates tied at the winning total length; `longest` means a
longer candidate won. `first_match` reports the firstmatch backend's rule
priority and preserves its regexp alternation behavior. `only_match` means
there was one candidate. EOF actions appear with reason `eof`; recovered
unmatched bytes appear with reason `unmatched` and no selected rule.

`--format json` returns an object with a `steps` array. Each candidate contains
`rule`, `patterns`, `length`, `trailing_length`, and `total_length`; lengths are
bytes. Steps include `byte_begin`, `byte_end`, `next_byte`, `state`,
`next_state`, `text`, `bytes`, `candidates`, `rule`, `patterns`, `reason`,
`action`, and `token`. `byte_end` is the scanner's matched end, while
`next_byte` reflects action changes such as `less`. `token` is the emitted
token's Ruby inspection string, or null when none was emitted. Invalid UTF-8
bytes are replaced in display text; `bytes` preserves the exact matched bytes.

Tracing adds candidate analysis and retains steps in memory; it is a debugging
tool, not a benchmark. Firstmatch candidate analysis reads the remaining
buffered input to inspect rules beyond the selected first match. It obeys the
lexer's buffer limit. Normal lexers do not load or run tracing code.

## DFA coverage with skeleton

```sh
flexr skeleton examples/calculator/lexer.flexr.rb
flexr skeleton examples/calculator/lexer.flexr.rb --format json --verify
```

The command reads the specification statically. For each lexical state,
it finds a shortest input that reaches each DFA transition. A transition is
identified by its source state, byte class, and destination. Several
transitions can share one input. Each case starts at byte zero in the named
lexical state, at the beginning of a line. The empty input exercises EOF.
UTF-8 witnesses finish their last character, and transitions with no valid
witness are listed as uncovered. Use `--format json` to preserve binary inputs
as byte arrays when they cannot be represented as UTF-8 text.

The JSON report contains `coverage` totals and a `cases` array. Each case
lists its lexical `state`, `input`, ordered `transitions`, and
`rule_bodies`. A rule body records its rule index and byte length from the
beginning of the input, including bodies accepted before the final transition.
The beginning- and end-of-line conditions are checked at those positions.
Rule selection, trailing context, and actions can change what a lexer emits.

`--verify` runs the specification and its actions in separate Ruby processes
for runtime, generated, and standalone modes. Use this option on trusted
specifications. The comparison includes tokens emitted before any error,
the last byte position and lexical state, and any reported errors. Token
values use the [snapshot representation](testing.md). Differing outcomes
are listed under `verification.mismatches`, and the command exits with
status 1. Matching errors are a valid parity result. Uncovered edges appear
in the report and leave the exit status unchanged.

## Exit statuses

Compare a lexer with Lrama/Bison-style declarations:

```sh
flexr check lexer.flexr.rb --grammar parse.y --warn-as-error
flexr tokens lexer.flexr.rb --format lrama
```

The check compares named `%token` declarations before the grammar's first `%%`
with `emits`. It handles multiline declarations, numeric token IDs, type tags,
aliases, and comments. Literal character tokens are excluded. This checks token
names, not grammar validity or whether every action actually emits its declared
token. Exported names must be identifiers; numeric IDs and aliases remain the
grammar author's responsibility.

| Status | Meaning |
|---:|---|
| `0` | Command completed; warnings do not fail by default |
| `1` | Specification, input, import, or generation failure |
| `2` | Invalid command-line usage |

`check --format json` writes one JSON array to stdout. Human diagnostics go to
stdout for `check` and errors go to stderr for command failures. Use
`--warn-as-error` when a warning should fail CI.

`--warn all` also includes informational equal-length rule overlaps
(`FLEXR-I001`). These reports include an input example and do not fail
`--warn-as-error`. See [Diagnostics](diagnostics.md#informational-diagnostics)
for the supported backends and states.
