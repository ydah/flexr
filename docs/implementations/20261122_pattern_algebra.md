# Automata for pattern algebra

The API contract is in [20261122_pattern_algebra.md / Decision](../adr/20261122_pattern_algebra.md#decision).

`Flexr::Pattern` copies and freezes literal arguments so callers can safely share a value across Ractors.
The static reader resolves named constants and retains their names for `flexr dot` and `flexr explain`.

`Automaton::Compiler` compiles union and concatenation through NFA alternation and sequence nodes.
Intersection and difference use bounded DFA products.
Complement uses the subject alphabet as the left operand of difference.
`upto` builds the language of strings ending in the terminator and removes the outgoing transitions of accepting states before embedding the DFA.
This prevents any path from extending beyond the first completed terminator.

The enclosing lexer ranks the fragments like ordinary compiled rules.
Generated and standalone lexers serialize the tables and retain pattern descriptions for traces and diagnostics.
