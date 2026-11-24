# CLI reference

The executable is `flexr`, with usage:

```text
flexr [COMMAND] SPEC.rb [options]
flexr diff LEFT.rb RIGHT.rb [options]
flexr new NAME --parser lrama|racc
```

Without a command, `flexr SPEC.rb` generates Ruby. `SPEC.rb` is normally a
`.flexr.rb` file, except for `import`, which accepts flex `.l` and Rexical
`.rex` input. Use `--from oedipus_lex` for the other `.rex` dialect.

## Commands

| Command | Purpose | Main output |
|---|---|---|
| `check SPEC` | Compile and render diagnostics | Human or JSON diagnostics |
| `fix SPEC` | Verify and apply supported diagnostic fixes | Updated spec, or full source with `--dry-run` |
| `diff LEFT RIGHT` | Compare the first rule selection in each lexical state | Shortest differences, or a proof status |
| `stats SPEC` | Report DFA states, byte classes, and table sizes | JSON |
| `tokens SPEC` | Print names declared by `emits` | Space-separated names |
| `dot SPEC` | Render the DFA as Graphviz DOT | DOT on stdout |
| `trace SPEC` | Print DFA states, or trace input when supplied | Human or JSON input trace |
| `skeleton SPEC` | Build shortest inputs that cover DFA transitions | Human or JSON coverage report |
| `explain SPEC` | List parsed rules, patterns, and DFA backup bounds | Text on stdout |
| `bench SPEC` | Run the benchmark harness | Benchmark output |
| `import INPUT` | Translate flex, Rexical, or oedipus_lex input | Ruby on stdout or `--output` |
| `new NAME --parser PARSER` | Create a Racc or Lrama calculator project | New project directory |

`trace` without input describes the automaton. To execute a specification and
inspect rule selection, pass `--input STRING` or `--input-file PATH`.
In shortest-match states, an input trace compares eligible body lengths.
With a live reader, it records the selected candidate without querying the
reader for additional candidates.
`dot` marks accepting states and accelerated regions for visual inspection.

For longest-match backends, `explain`, structural `trace`, and `dot` show
the maximum DFA backup in bytes for each lexical state. This is the longest path through nonaccepting
states after an acceptance. A reachable nonaccepting cycle makes the bound
unbounded. This analysis describes the rule-body DFA. Runtime conditions
such as anchors, trailing context, and `expect:` can change which accepts
are usable. The bound also excludes bytes read before the first acceptance.

## Options

| Option | Values / argument | Applies to |
|---|---|---|
| `-o, --output PATH` | File path | Generation and import |
| `-b, --backend NAME` | `table`, `direct`, `firstmatch`, `auto` | Compilation |
| `--token-kind KIND` | `array`, `struct`, `yield` | Generated/runtime contract |
| `--accel MODE` | `auto`, `strscan`, `regexp`, `none` | Runtime optimization |
| `--standalone` | Flag | Generation |
| `--eval` | Flag | Generation and check |
| `--lrama-grammar PATH` | Lrama grammar file | Generation |
| `--table-compression VALUE` | `none`, `rows`, `full` | Generation |
| `--table-format VALUE` | `literal`, `packed` | Generation |
| `--max-dfa-states N` | Positive integer | Compilation and comparison search. For `fix`, it limits the comparison search. |
| `-W, --warn LEVEL` | `all`, `default`, `none` | Check and generation |
| `--warn-as-error` | Flag | Check and generation |
| `--color WHEN` | `auto`, `always`, `never` | Human diagnostics |
| `--format FMT` | `human`, `json`, `lrama` | `lrama` is for tokens only |
| `--grammar PATH` | Grammar path | Compare `%token` names with `emits` during check |
| `--target 2.0` | none | Static check migration requirements and structured-token declarations |
| `--dry-run` | Flag | Preview fixes on stdout |
| `--accept-changes` | Flag | Approve changed or unverified fixes |
| `--rule N` | Non-negative integer | Explain |
| `--input STRING` | Literal input, including an empty string | Trace |
| `--input-file PATH` | Input file | Trace and bench |
| `--generated` | Run the generated scanner | Input trace |
| `--residuals` | Show remaining DFA expressions | Explain and trace |
| `--verify` | Execute the generated cases in all three modes | Skeleton |
| `--from oedipus_lex` | Select the oedipus_lex `.rex` dialect | Import |
| `--parser PARSER` | `lrama` or `racc` | New project |

The complete help output is kept as a checked snapshot:

<!-- flexr-help:start -->
Usage: flexr [COMMAND] SPEC.rb [options]
       flexr diff LEFT.rb RIGHT.rb [options]
       flexr new NAME --parser lrama|racc

Commands: check, fix, diff, stats, tokens, dot, explain, trace, skeleton, bench, import, new
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
      --lrama-grammar PATH    Precompute parser-state contexts for generation
      --grammar PATH          compare emits with grammar %token declarations (check only)
      --input STRING          trace input (executes SPEC actions)
      --input-file PATH       trace or benchmark input
      --generated             trace generated scanner
      --residuals             show remaining DFA expressions (explain or trace)
      --verify                verify skeleton across all modes (executes SPEC actions)
      --target 2.0            report migration requirements (static check only)
      --dry-run               print the fixed spec without writing (fix only)
      --accept-changes        apply changed or unverified fixes (fix only)
      --from oedipus_lex      read an oedipus_lex .rex file (import only)
<!-- flexr-help:end -->

## Automatic fixes

`flexr fix lexer.flexr.rb` compiles the proposed specification and compares
rule selection before and after the change. It saves fixes that preserve rule
selection and keeps the original line endings.

When rule selection changes, the command shows the shortest input that
demonstrates the change, with the selection before and after the fix. An
inconclusive comparison reports its reason. This can happen when a fix repairs
a specification that could not compile.

In an interactive terminal, answer `y` or `yes` to apply either kind of fix.
In a script, pass `--accept-changes` to approve such a fix. Without approval,
the command exits with status 1 for a change or 2 for an inconclusive comparison.

`flexr fix lexer.flexr.rb --dry-run` prints the proposed Ruby source to
stdout. Any counterexample or inconclusive result goes to stderr. A valid
preview exits with status 0 and leaves the file untouched.

The command reads the specification statically. Ruby LSP offers the same edits
as quick fixes for DFA backends.

- `FLEXR-W013` makes ordinary groups in direct regexp rule arguments non-capturing.
  Rules with named captures keep their original groups.
- `FLEXR-W001` raises the priority of a shadowed literal with `emit:` when the
  DFA shows that every previous winner can still win elsewhere. After the
  change, the literal emits its own token type on equal-length matches.
- `FLEXR-E014` rewrites a quoted lazy dot-star to an absence group that stops
  at the first closing quote. It preserves the regexp's newline handling.
- `FLEXR-I003` groups adjacent literal rules into a keyword table when the
  compiler verifies the change and there are no intervening comments.

## Compare lexer specifications

```sh
flexr diff previous.flexr.rb updated.flexr.rb
flexr diff previous.flexr.rb updated.flexr.rb --format json
```

For each lexical state, `diff` compares one rule selection using each
specification's backend. Under `firstmatch`, changing `/a|ab/` to `/ab|a/`
produces the witness `ab`, with selected lengths of one and two bytes.
The command checks the selected rule body's byte length, token type after
keyword remapping, channel, and literal state operations. A skipped rule still
selects a body. An unmatched position is a separate outcome. The command
reads both specifications statically and can compare trailing context,
lookahead, and lookbehind.

The shortest witness is measured in bytes. It includes any input prefix
needed for left context. The reported offset marks where matching starts in the
named state. UTF-8 witnesses contain complete Unicode scalars. Binary
witnesses may contain any byte. In JSON, each entry in `states` gives a
`status`. A witness adds `input`, `offset`, and the `left` and `right`
selections. An input that cannot be represented as UTF-8 is a byte array.
A selection includes the rule index, body byte length, and static effect.
Names that cannot be encoded as UTF-8 also use byte arrays.

The command compares declarations and accepts equal rules at different source
indices. Token values, arbitrary Ruby actions, EOF handlers, and later tokens
are outside the comparison. A reachable opaque action may make a state
inconclusive. A state can also be inconclusive if the encodings differ, the
comparison reaches `--max-dfa-states`, or a `firstmatch` pattern needs a
matching operation the comparison does not model. Examples include Ruby's
native case folding, some bounded repetitions that can match empty text,
and lookahead with named captures.

Exit status 0 means all compared states are equal. Exit status 1 means at
least one state differs. Exit status 2 means the command encountered a
compilation error or could not establish equality.

## New parser project

`flexr new NAME --parser PARSER` creates a directory in the current directory.
The name must start with a letter or digit and may also contain hyphens and
underscores. Choose a name that is available. Follow the generated README or
the [calculator parser tutorial](../tutorial/build-a-calculator-parser.md)
to install dependencies, build the parser, and run the tests.

## DFA residuals

```sh
flexr explain lexer.flexr.rb --rule 0 --residuals
flexr trace lexer.flexr.rb --residuals
flexr trace lexer.flexr.rb --input 'abbc' --residuals --format json
```

A residual describes the bytes a rule can still match after the DFA has read
a prefix. After a rule like `/ab*c/` reads `a`, its residual is `b*c`.
Entries identify the rule and pattern by their zero-based indices.
`ε` means the empty string. For a reused DFA fragment, `DFA[fragment][state]`
identifies the remainder within that fragment. Anchor and trailing-context
checks still apply when the lexer selects a rule.

With `--residuals`, explain lists residuals by lexical state and minimized
DFA state. Use `--rule` to limit the listing to one rule. Trace without input
adds residuals to the state transition table. With input, it adds a path from
the start of each matched step through its matched bytes. The JSON
`dfa_path` field includes each entry's `byte_offset`, `state`, and
`residuals`. Each residual has a `rule`, `pattern`, and `expression`.
These views require a longest-match backend.

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
| `1` | Specification, input, import, generation, or project creation failure |
| `2` | Invalid command-line usage |

`check --format json` writes one JSON array to stdout. Human diagnostics go to
stdout for `check` and errors go to stderr for command failures. Use
`--warn-as-error` when a warning should fail CI.

`--warn all` also includes informational equal-length rule overlaps
(`FLEXR-I001`). These reports include an input example and do not fail
`--warn-as-error`. See [Diagnostics](diagnostics.md#informational-diagnostics)
for the supported backends and states.
