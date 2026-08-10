# flexr

flexr is a Pure Ruby longest-match lexer generator. A specification is an
ordinary Ruby file with a small internal DSL, so it can be required directly
during development or transformed into generated Ruby for deployment.

## Installation

```ruby
# Gemfile
gem "flexr"
```

The runtime and generated lexers have no runtime gem dependencies. The source
generator uses Prism on Ruby 3.3 and newer.

| Path | Ruby requirement | Dependencies |
|---|---:|---|
| Runtime mode | 3.1+ | none |
| Generated lexer | 3.1+ | none |
| `flexr` generator | 3.3+ recommended | Prism (default gem) |

## Quick start

```ruby
require "flexr"

class CalculatorLexer < Flexr::Lexer
  rule(/[ \t\n]+/, skip: true)
  rule(/[0-9]+/) { emit :INTEGER, text.to_i }
  rule(/\+/) { emit :PLUS }
end

CalculatorLexer.new("12 + 3").tokens
# => [[:INTEGER, 12], [:PLUS, "+"], [:INTEGER, 3]]
```

flexr chooses the longest match at the current position. Source order breaks
ties, which means rule reordering cannot accidentally make a shorter rule win.

The runtime path is useful during development: `require` the specification and
instantiate its lexer. The generated path is the deployment path and embeds
the compiled tables.

## Measured performance

The local CRuby 4.0.0 sample on 2026-08-10 used the deterministic JSON
benchmark input (140,000 bytes, three measured iterations): runtime `1.691
MB/s`, generated `1.604 MB/s`, and the handwritten `StringScanner` baseline
`8.597 MB/s`. Runtime is `1.042x` generated; generated is `0.187x` the
handwritten baseline. These are measurements on one machine, not guarantees;
run `ruby -Ilib benchmark/run.rb` for your environment. Generated mode is above
the v1.0 measured regression floor of 0.18x, while the 0.7x handwritten
comparison remains a stretch target; no target-reaching performance claim is
made. See [ADR 0019](docs/adr/0019-measured-performance-floor.md).

## Generating a lexer

```sh
flexr lib/calculator/lexer.flexr.rb -o lib/calculator/lexer.rb
```

Generation statically evaluates regular-expression literals, arrays, constants,
`.freeze`, and `Regexp.union`. Dynamic pattern construction is rejected with
`FLEXR-E017`; use `--eval` only when intentionally executing the specification
at generation time.

## Pattern support

Character classes, alternation, repetition, Unicode properties, boundary
anchors, and `/i`, `/m`, `/x`, `/n` are supported. Look-around, backreferences,
lazy or possessive quantifiers, `\b`, and conditional expressions are rejected
with `FLEXR-E014` and an alternative suggestion.

States, EOF actions, `followed_by:`, `token_kind`, and location reporting are
available through the runtime DSL. The implementation is byte-oriented, which
also makes invalid UTF-8 input fail with a normal lexer error instead of
entering an invalid character loop.

## Security

flexr is a code generator. Actions are Ruby code and are copied into generated
files. Do not process untrusted specification files. The `--eval` option also
executes the specification during generation and should only be used with
trusted input.

## Development

```sh
bundle install
bundle exec rake test
bundle exec rake modes:equivalence
bundle exec rake golden:verify accel:equivalence dogfood:verify examples:check
bundle exec rake generated:verify unicode:verify
bundle exec rake bench:regression
bundle exec rake coverage
```

The verification gates are independent: golden checks generated-source digests,
acceleration checks the extracted byte regions, and dogfood checks that each
generated Ruby file is syntactically valid and contains a compiled payload.
`bench:regression` requires the checked-in baseline and fails when its input
identity changes or throughput drops by more than 10 percent.
`coverage` reports line coverage for `lib/flexr` and fails below the 95% CI
gate.

`dot:verify` requires Graphviz and parses the CLI DOT output through
`dot -Tsvg`; it is run in the dedicated CI tooling job.

For diagnostics, use `flexr check SPEC.rb --format json`, `flexr stats`,
`flexr dot`, or `flexr trace`. `--warn-as-error` turns compiler warnings into a
failed generation/check. `NO_COLOR=1` disables diagnostic colors.

## License

MIT
