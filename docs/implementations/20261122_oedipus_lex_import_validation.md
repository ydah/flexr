# oedipus_lex import validation

`Flexr::Importer::OedipusLex` resolves only declared regexp macros. It
translates skip actions and statically recognizable token pairs, validates
patterns against the first-match backend, and reports unsupported constructs
at their source positions. See the [migration guide](../how-to/migrate-from-oedipus-lex.md#supported-forms)
for the accepted subset.

On 2026-11-22, the parity trial matched 274 token pairs across six inputs
against oedipus_lex 2.6.3 in Flexr's runtime, generated, and standalone modes
on Ruby 3.4.9 and 4.0.9. The [ruby_parser 3.22.0 trial](../how-to/migrate-from-oedipus-lex.md#trial-against-ruby_parser)
exposed unsupported hooks, guards, and actions and produced no output.
See [20261122_import_oedipus_firstmatch.md / Decision](../adr/20261122_import_oedipus_firstmatch.md#%E6%B1%BA%E5%AE%9A) for the compatibility decision.
