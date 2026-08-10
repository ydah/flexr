# flexr

[![CI](https://github.com/ydah/flexr/actions/workflows/main.yml/badge.svg)](https://github.com/ydah/flexr/actions/workflows/main.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.txt)

Pure Ruby longest-match lexer generator.

Write a lexer as ordinary Ruby, run the specification directly during
development, and generate deterministic Ruby code for deployment.

flexr always chooses the longest rule at the current position. When rules match
the same number of bytes, definition order breaks the tie, so reordering rules
cannot make a shorter token win.

## Get started

### Install

```sh
gem install flexr
```

Or add it to your Gemfile:

```ruby
gem "flexr"
```

| Path | Ruby | Dependency |
|---|---:|---|
| Runtime mode | 3.1+ | None |
| Generated lexer | 3.1+ | None |
| `flexr` generator | 3.3+ recommended | Prism (default gem) |

### Write a lexer

```ruby
# lexer.flexr.rb
require "flexr"

class CalculatorLexer < Flexr::Lexer
  rule(/[ \t\n]+/, skip: true)
  rule(/[0-9]+/) { emit :INTEGER, text.to_i }
  rule(/\+/) { emit :PLUS }
end

CalculatorLexer.new("12 + 3").tokens
# => [[:INTEGER, 12], [:PLUS, "+"], [:INTEGER, 3]]
```

Require the specification to use runtime mode. Choose between `next_token`,
`tokens`, and `each_token` depending on the consumer.

### Generate for deployment

```sh
flexr lexer.flexr.rb -o lexer.rb
```

The generator statically evaluates regular-expression literals, constants,
arrays, `.freeze`, and `Regexp.union`. Dynamic expressions are rejected with
`FLEXR-E017`; use `--eval` only with a trusted specification when runtime
evaluation is intentional.

## Choose a mode

| Mode | Use it for | Behavior |
|---|---|---|
| Runtime | Development, tests, and exploration | Requires the Ruby specification and builds its DFA at runtime |
| Generated | Deployment and reproducible artifacts | Reads the DSL with Prism and embeds compiled tables in Ruby |

Actions remain Ruby code in generated files. Do not process untrusted
specifications.

## What it provides

- **Deterministic matching** — longest-match, source-order ties, and backup
- **Ruby DSL** — `rule`, `state`, `on_eof`, `followed_by:`, and `emits`
- **Runtime APIs** — `:array`, `:struct`, and `:yield` token kinds; locations; IO input;
  and `:raise` / `:token` / `:panic` error recovery
- **Unicode** — vendored UCD 15.1.0 properties, POSIX classes, and simple case folding
- **Code generation** — `table`, `direct`, and `firstmatch` backends; table compression;
  and region acceleration
- **Diagnostics** — `flexr check`, JSON output, `stats`, `dot`, `trace`, and `explain`
- **Parser integration** — the `racc_next_token` protocol for Racc and Lrama

### Supported regular expressions

The DFA subset includes literals, concatenation, alternation, groups, character
classes, Unicode properties, pattern-edge `^` / `$`, greedy `*` / `+` / `?` /
`{n,m}`, and `/i`, `/m`, `/x`, and `/n`.

Look-around, backreferences, lazy or possessive quantifiers, `\b`, and
conditional expressions are rejected with `FLEXR-E014` and an alternative such
as `followed_by:` or a state transition.

## CLI

```sh
# Diagnostics; JSON is useful in CI
flexr check lexer.flexr.rb --format json

# Inspect state counts, character classes, and table sizes
flexr stats lexer.flexr.rb

# Visualize and trace a DFA
flexr dot lexer.flexr.rb > lexer.dot
flexr trace lexer.flexr.rb

# Inspect rules and declared tokens
flexr explain lexer.flexr.rb --rule 0
flexr tokens lexer.flexr.rb
```

`flexr import` migrates common actions from flex `.l` and Rexical `.rex` files.
Untranslated C actions are reported as `FLEXR-TODO` and return exit code 1.
Incomplete output is never written to the requested output path. Run
`flexr check` after rewriting imported actions.

## Examples

- [JSON lexer](examples/json/README.md) — minimal runtime and generated example
- [Toy language](examples/toy_lang/README.md) — constants interpolated into patterns
- [Ruby subset](examples/ruby_subset/README.md) — ordinary Ruby preserved during transformation
- [Racc integration](examples/with_racc/README.md)
- [Lrama integration](examples/with_lrama/README.md)

## Measured performance

The following sample was measured on local CRuby 4.0.0 on 2026-08-10 using a
deterministic 140,000-byte JSON input and three iterations. It is an observation
from one machine, not a performance guarantee.

| Mode | MB/s | Tokens/s | Handwritten ratio |
|---|---:|---:|---:|
| Runtime | 1.671 | 596,789 | 0.194x |
| Generated | 1.604 | 572,954 | 0.187x |
| Handwritten `StringScanner` | 8.597 | 3,070,499 | 1.000x |

See the [performance log](docs/perf-log.md) for measurement conditions and
`c_byte` / `c_token` estimates. The 0.7x comparison is an unmet stretch target;
flexr does not claim to have reached it.

## Development

```sh
bundle install
bundle exec rake test
bundle exec rubocop
bundle exec rake modes:equivalence golden:verify accel:equivalence dogfood:verify
bundle exec rake generated:verify unicode:verify direct:verify examples:check
bundle exec rake test:differential fuzz
bundle exec rake bench:regression
bundle exec rake coverage
```

CI runs the Ruby and OS matrix, generated-artifact checks, one million
differential comparisons, and 10,000 fuzz inputs per example on every push,
pull request, and scheduled run. Benchmark CI uses a host-portable baseline
gate; release verification also applies the measured absolute floor.

## Documentation

- [Reference](docs/reference/README.md) — DSL, CLI, and regular-expression subset
- [Runtime mode](docs/guide/01-runtime.md)
- [Generation mode](docs/guide/02-generation.md)
- [States](docs/guide/03-states.md)
- [Trailing context](docs/guide/04-trailing-context.md)
- [Racc / Lrama integration](docs/guide/05-parser-integration.md)
- [Performance tuning](docs/guide/06-performance.md)
- [Migration from flex / Rexical](docs/guide/07-migration.md)
- [Regexp limitations](docs/guide/08-regexp-limitations.md)
- [Static evaluation](docs/guide/09-static-evaluation.md)
- [Releasing](docs/RELEASING.md)

## Security

flexr is a code generator. Actions are copied into generated files as Ruby
code. Do not process untrusted specification files. `--eval` executes the
specification during generation and should be limited to trusted input.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
