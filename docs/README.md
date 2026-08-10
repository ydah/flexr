# flexr documentation

The documentation is organized by reader intent. The executable specifications
under `examples/` are the source of truth for commands and token output; prose
pages explain how to use those specifications.

## Choose a path

| You want to... | Read |
|---|---|
| Build your first lexer | [Build a calculator lexer](tutorial/build-a-calculator-lexer.md) |
| Run a specification | [Run at runtime](how-to/run-a-lexer-at-runtime.md) |
| Generate Ruby | [Generate a lexer](how-to/generate-a-lexer.md) |
| Ship one file | [Deploy a standalone lexer](how-to/deploy-a-standalone-lexer.md) |
| Add states or trailing context | [States](how-to/use-states.md), [trailing context](how-to/use-trailing-context.md) |
| Integrate a parser | [Racc](how-to/integrate-with-racc.md), [Lrama](how-to/integrate-with-lrama.md) |
| Migrate an existing lexer | [flex](how-to/migrate-from-flex.md), [Rexical](how-to/migrate-from-rexical.md) |
| Look up exact behavior | [Reference](reference/README.md) |
| Understand design trade-offs | [Explanation](explanation/) |

## Tutorial

- [Build a calculator lexer](tutorial/build-a-calculator-lexer.md)

## How-to

- [Run a lexer at runtime](how-to/run-a-lexer-at-runtime.md)
- [Generate a lexer](how-to/generate-a-lexer.md)
- [Deploy a standalone lexer](how-to/deploy-a-standalone-lexer.md)
- [Use states](how-to/use-states.md)
- [Use trailing context](how-to/use-trailing-context.md)
- [Handle errors](how-to/handle-errors.md)
- [Track token locations](how-to/track-token-locations.md)
- [Integrate with Racc](how-to/integrate-with-racc.md)
- [Integrate with Lrama](how-to/integrate-with-lrama.md)
- [Migrate from flex](how-to/migrate-from-flex.md)
- [Migrate from Rexical](how-to/migrate-from-rexical.md)
- [Tune performance](how-to/tune-performance.md)

## Reference

- [DSL](reference/dsl.md)
- [Runtime](reference/runtime.md)
- [Actions](reference/actions.md)
- [Tokens and locations](reference/tokens-and-locations.md)
- [Errors](reference/errors.md)
- [Regexp compatibility](reference/regexp.md)
- [CLI](reference/cli.md)
- [Diagnostics](reference/diagnostics.md)
- [Generated artifacts](reference/generated-artifacts.md)
- [Public API](reference/public-api.md)
- [Compatibility](reference/compatibility.md)

## Explanation

- [Matching semantics](explanation/matching-semantics.md)
- [Runtime versus generated](explanation/runtime-vs-generated.md)
- [Backends](explanation/backends.md)
- [Unicode and encoding](explanation/unicode-and-encoding.md)
- [Security model](explanation/security-model.md)

The [performance log](perf-log.md), [architecture decisions](adr/),
[internals notes](internals/README.md), and [release procedure](RELEASING.md)
are maintainer-facing documents.
