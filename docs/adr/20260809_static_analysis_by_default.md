# ADR: Generate from static source unless the caller requests evaluation

- Status: Accepted
- Decision date: 2026-08-09
- Related: [Original decision](https://github.com/ydah/flexr/commit/5a4b46ae670376c4373e4b92e8cc80d4079ee691), [20260809_spec_is_plain_ruby.md / Decision](20260809_spec_is_plain_ruby.md#decision)

## Context

A flexr specification may build patterns using Ruby method calls or values
from its environment. If generation evaluated every specification, building
a lexer could run arbitrary Ruby and depend on build-time environment values.
`Flexr::Generator#generate` selects between the source reader and runtime
evaluation. `Flexr::Source::StaticEval#call` accepts a constrained set of
expressions.

## Decision

Resolve supported deterministic expressions during generation without running
the specification. Report dynamic expressions that affect lexer declarations
with `FLEXR-E017`. Require an explicit `--eval` to execute the specification
and discover its runtime rule declarations.

## Alternatives considered

Always evaluating specifications would accept more Ruby patterns, but would
give an ordinary generation command the side effects of running the
application code it reads.

## Consequences

Builds can statically generate lexers from supported declarations. Authors
of dynamic specifications must either rewrite those declarations or choose
to execute trusted code with `--eval`. The generated file contains the Ruby
actions and executes them when used. The [security model](../explanation/security-model.md)
describes the boundaries for both generation and execution.
