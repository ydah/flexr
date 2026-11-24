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

Run `ruby tools/gen_grapheme_automaton.rb UCD_DIRECTORY` with the same snapshot
to regenerate the grapheme automaton. It uses Grapheme_Cluster_Break,
Indic_Conjunct_Break, and Extended_Pictographic to produce both byte transitions
and the regexp used for ordered capture matching. The grapheme specs exercise
the official Unicode grapheme break corpus over one-byte input chunks. Refresh
`spec/fixtures/grapheme_break_test_15_1_0.txt` and its reference in the spec when
changing the snapshot version.
