# Generation for keyword tables, channels, and priority

Flexr 2.1 introduced keyword tables, trivia channels, and rule priority.
The generator carries their metadata only for specifications that use it.

## Keyword tables

The emission policy is in [20261122_classify_keywords_after_matching.md / Decision](../adr/20261122_classify_keywords_after_matching.md#decision).

`Automaton::KeywordTables.diagnostics` validates spellings against full acceptances and checks the native first match on `firstmatch` rules.
`Keywords::Emission` remaps runtime tokens after matching.
The generator writes the same lookup into actions for the participating rules and stores the table in the generated configuration.
The table adds no DFA transitions and leaves the artifact ABI unchanged.

## Trivia channels

The token-consumption contract is in [20261122_trivia_channels.md / Decision](../adr/20261122_trivia_channels.md#decision).

The generator stores channel metadata when named channels are used.
Standalone output embeds the trivia runtime for those specifications.
Ordinary lexers keep their scanner and emission path and ordinary generated artifacts retain the same payload.
Structured tokens store the immutable trivia metadata outside their data members.

## Rule priority

The precedence contract is in [20261122_explicit_rule_priority.md / Decision](../adr/20261122_explicit_rule_priority.md#decision).

Generated and standalone artifacts carry priority only for rules that use a nonzero value.
`IR::Rule#loses_priority_tie?` compares priority and source index when longest-match candidates have equal length.
Warnings, overlap examples, and input traces identify an explicit priority when it decides a tie.
