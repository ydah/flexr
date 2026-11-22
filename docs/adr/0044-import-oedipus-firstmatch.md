# ADR 0044: Preserve first-match order when importing oedipus_lex

## Context

Rexical and oedipus_lex share the `.rex` extension. Flexr's existing
Rexical migration emits longest-match rules and reports known changes in
rule selection. The [oedipus_lex rules reference](https://docs.seattlerb.org/oedipus_lex/)
describes Ruby regexps and source-order rule selection.

## Decision

Use `flexr import --from oedipus_lex` to select the format. Emit
`backend :firstmatch` and keep the source rule order and regexp alternative
order. Resolve only declared regexp macros. Translate skip actions and
statically recognizable token pairs. Validate the regexp against the
firstmatch backend's supported syntax before emitting it.

Report unsupported code and directives with original file and line numbers.
Write output only when every part of the specification is supported. Keep Rexical import behavior when no format is supplied.

## Evidence

The [migration guide](../how-to/migrate-from-oedipus-lex.md#trial-against-ruby_parser)
records the unsupported parts of the ruby_parser 3.22.0 lexer. A separate
parity check with oedipus_lex 2.6.3 matched 274 token pairs across six inputs
in runtime, generated, and standalone Flexr modes on Ruby 3.4.9 and 4.0.9.
