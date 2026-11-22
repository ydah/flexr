# ADR: Preserve first-match order when importing oedipus_lex

- Status: Accepted
- Decision date: 2026-11-22
- Related: [#90](https://github.com/ydah/flexr/pull/90)

## Context

Rexical and oedipus_lex both use `.rex`. `Flexr::Importer.import` reads that
extension as Rexical by default. The [oedipus_lex 2.6.3 documentation](https://docs.seattlerb.org/oedipus_lex/)
defines first-match selection. Its generated `next_token` tries the eligible
rules in source order. For example, a leading `/a/` consumes only `a`
from `ab` even when a later `/ab/` rule could consume both bytes.

## Decision

Select the oedipus_lex dialect with `flexr import --from oedipus_lex`.
Generate `backend :firstmatch` and preserve rule order and Ruby regexp
alternative order. Keep Rexical as the default for `.rex` files.

Translate only source forms whose behavior can be preserved statically.
Report unsupported input against its source location and write output only
when the entire translation succeeds.

## Out of scope

The supported translation subset and parity measurements are recorded in
[the oedipus_lex import validation notes](../implementations/20261122_oedipus_lex_import_validation.md).

## Alternatives considered

Selecting a dialect from the shared extension would break the existing Rexical
default or risk reading an oedipus_lex file as Rexical. Emitting longest-match
rules would change the token stream where two rules match the same prefix.
Emitting partial output for unsupported actions could silently drop tokens
or other action effects.

## Consequences

Callers select the dialect explicitly and receive a Flexr specification with
the source lexer's precedence for supported rules. Specifications with
unsupported hooks, guards, or actions require manual migration.
See the [oedipus_lex migration guide](../how-to/migrate-from-oedipus-lex.md).
