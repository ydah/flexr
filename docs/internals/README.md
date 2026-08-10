# Internals

This is maintainer-facing material. The public contract is in
[reference/public-api.md](../reference/public-api.md); implementation choices
are explained in the [architecture decisions](../adr/) and
[explanation pages](../explanation/).

Both runtime and generated modes compile the same byte-oriented model: regexp
AST, Thompson NFA, byte-class DFA, deterministic minimization, and last-accept
tracking. Generated output embeds compiled tables and generated dispatch code;
runtime mode uses the interpreter and optional acceleration paths.

The internal names `Flexr::IR`, `Flexr::Automaton`, `Flexr::Codegen`, and
`__flexr_*` are not compatibility-stable.
