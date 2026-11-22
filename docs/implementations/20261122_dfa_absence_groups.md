# DFA construction for absence groups

The language contract is in [20261122_dfa_absence_groups.md / Decision](../adr/20261122_dfa_absence_groups.md#decision).

`Regexp::Normalizer` represents `(?~X)` as the subject's universe minus a universe string followed by `X` and another universe string.
For nullable `X`, it emits a failing fragment without building the product.
The byte classes for a UTF-8 universe exclude invalid scalar encodings.

`Automaton::Compiler#compile_difference` determinizes both operands and passes them to `DFAOperations.difference`.
The product treats a missing transition in the excluded language as rejection.
It keeps only strings in the universe, minimizes the result, and inserts it into the enclosing NFA fragment.
The surrounding rules can therefore concatenate or alternate with absence groups and still use normal longest-match selection.
The compiler applies `max_dfa_states` to both operand automata, their product, and the enclosing DFA.
Serialized artifacts keep the existing DFA representation.
