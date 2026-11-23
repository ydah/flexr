# ADR: Build lexer DFAs from regular-expression derivatives

- Status: Proposed
- Decision date: 2026-11-23
- Related: [Comparison compiler](https://github.com/ydah/flexr/pull/112), [Residual diagnostics](https://github.com/ydah/flexr/pull/113), [Pattern algebra](https://github.com/ydah/flexr/pull/114), [20260809_byte_level_dfa.md](20260809_byte_level_dfa.md#decision), [20260809_leftmost_longest.md](20260809_leftmost_longest.md#decision)

## Context

In flexr 2.2.0, `Automaton::Compiler` constructs an NFA for each lexical
state and determinizes sets of NFA states. Subtraction, intersection, and
complement in pattern values use a separate DFA product construction.
A subset describes a collection of NFA states. To explain what can match
after a prefix, the lexer needs the remaining language of each rule.

The derivative comparison constructs that remainder for every rule and
pattern over the existing byte classes. The repository's lexer specifications
and seeded regexp tests produce isomorphic minimized DFAs with both
constructors. The comparison checks transitions for every byte, acceptance
order, pattern indices, anchor conditions, and the trailing-context DFAs.
[Regular-expression derivatives re-examined](https://people.cs.uchicago.edu/~jhr/papers/2009/jfp-re-derivatives.pdf)

## Decision

Use derivatives by default for runtime compilation and static generation.
A state represents a vector of remaining byte languages. A nullable entry
contributes its rule's acceptance label. Minimize the resulting DFA and
apply the existing longest-match and priority contracts when selecting tokens.

Keep subset construction as an internal reference through the first minor
release that ships derivatives by default. Cache keys include the constructor
so each reference run can load its own DFA.

## Out of scope

Lazy construction belongs to the startup work. Syntax and eligibility for new
regexp operators belong to their matching semantics decisions. The records for
these decisions are undecided.

## Alternatives considered

Keep subset construction and derive expressions solely for diagnostic output.
This would leave separate paths for the lexer and its explanations, and pattern
operations would still need a second construction.

Offer both constructors as public configuration. Equivalent accepted byte
languages give users little reason to select a compiler. A public choice would
make both paths part of the maintenance and compatibility contract.

## Consequences

The compiler can describe intermediate states in terms of the input each rule
can still match. Pattern operations use the same constructor as rule bodies.
DFA state numbers identify states within the compiled machine.

Compilation time depends on the specification. The warmed Unicode identifier
fixture took 122 ms with subset construction and 145 ms with derivatives in
the seven-sample comparison on Ruby 4.0.9. The compiler reuses prebuilt Unicode
property automata, and the disk cache can reuse the final tables.
[Compilation benchmark](../perf-log.md#2026-11-23-compare-dfa-construction-by-derivatives)
