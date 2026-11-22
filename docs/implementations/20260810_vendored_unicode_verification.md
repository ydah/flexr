# Verify and regenerate the vendored Unicode snapshot

The decision in [20260810_vendored_unicode_contract.md / Decision](../adr/20260810_vendored_unicode_contract.md#%E6%B1%BA%E5%AE%9A)
defines which Unicode data flexr uses. `tools/gen_unicode_tables.rb`
regenerates the source tables from an explicitly supplied Unicode Character
Database directory.

`rake unicode:verify` checks the snapshot version and range invariants. Its
UTF-8 checks cover all scalar singletons and 100,000 deterministic random
ranges. Regenerate the golden artifacts when updating the snapshot.
