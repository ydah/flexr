# ADR: Run lexers with Ruby and its standard library

- Status: Accepted
- Decision date: 2026-08-09
- Related: [Original decisions](https://github.com/ydah/flexr/commit/5a4b46ae670376c4373e4b92e8cc80d4079ee691)

## Context

Runtime mode receives Ruby `Regexp` and `Proc` objects from the evaluated DSL.
The ahead-of-time generator starts with source text and needs positions in
that source to preserve user Ruby while replacing DSL declarations.
`Flexr::Source::PrismReader#read` uses Prism for that task. Loading
`flexr/runtime` does not load the source reader.

## Decision

Keep flexr's runtime and the runtime embedded in generated lexers on Ruby's
standard library. Use Prism in tooling that reads specifications, including
ahead-of-time generation. Normal generated lexers load the flexr runtime.
Standalone generated lexers embed their runtime.

## Out of scope

Applications supply the dependencies used by their own Ruby actions. See the
decision in [20260809_spec_is_plain_ruby.md / Decision](20260809_spec_is_plain_ruby.md#decision).

## Alternatives considered

A shared source-reading path would require Prism in deployments. The
runtime already receives the expressions and actions it needs from evaluated
declarations, and deployments of ahead-of-time generated lexers would carry
an unused parser dependency.

## Consequences

Users install Prism where they generate code. They can deploy a standalone
lexer as a single file on a compatible Ruby. Runtime features and optional
accelerators must remain available within that deployment boundary. The
[dependency matrix](../reference/generated-artifacts.md#dependency-matrix)
defines the requirements for each mode.
