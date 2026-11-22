# Verify and prepare the flexr 2 runtime

The [generated-only workflow](../../.github/workflows/generated-ruby34.yml)
loads generated Ruby on the supported deployment minimum without requiring
the source generator. It verifies the runtime requirement in
[20261122_ruby_34_minimum.md / Decision](../adr/20261122_ruby_34_minimum.md#decision).

`Flexr::Runtime::Location` stores lazy column values in a frozen pair. The
column readers need neither a reference to the lexer nor a mutable record.
See [20261122_immutable_tokens_and_locations.md / Decision](../adr/20261122_immutable_tokens_and_locations.md#decision).

`Flexr::Generated.shareable!` materializes dense transition rows before it
makes the generated lexer data shareable. This replaces the lazy lookup
state that would otherwise be initialized by workers. See
[20261122_opt_in_ractor_sharing.md / Decision](../adr/20261122_opt_in_ractor_sharing.md#decision).
