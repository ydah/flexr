# Verify and regenerate the vendored Unicode snapshot

The decision in [20260810_vendored_unicode_contract.md / Decision](../adr/20260810_vendored_unicode_contract.md#decision)
defines which Unicode data flexr uses. `tools/gen_unicode_tables.rb`
regenerates the source tables from an explicitly supplied Unicode Character
Database directory.

Run `ruby tools/gen_unicode_automata.rb` after refreshing the source tables.
It builds UTF-8 property automata from the vendored ranges and case folds.
`rake unicode:verify` checks that the automata regenerate byte for byte, and
that the snapshot version and range invariants hold. Its UTF-8 checks cover
all scalar singletons and 100,000 deterministic random ranges. Regenerate
the golden artifacts when updating the snapshot.
