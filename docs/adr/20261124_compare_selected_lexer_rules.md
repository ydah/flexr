# ADR: Compare selected rule effects and body lengths when diffing lexer specifications

- Status: Proposed
- Decision date: 2026-11-24
- Related: [20260809_leftmost_longest.md / Decision](20260809_leftmost_longest.md#decision), [20261122_stable_explicit_firstmatch.md / Decision](20261122_stable_explicit_firstmatch.md#decision), [20261122_classify_keywords_after_matching.md / Decision](20261122_classify_keywords_after_matching.md#decision)

## Context

Two lexer specifications can accept the same language and choose different
tokens. For example, a higher-priority rule can win a same-length tie after
a refactoring. `Runtime::Interpreter#consider_acceptances` also uses trailing
context in the ranking, so it can choose a shorter body even when the
accepted body languages stay the same. `Keywords::Emission#execute` can
change the emitted token type after the body has won.

The `flexr fix` workflow needs evidence that a rewrite preserves these
observable choices. Static compilation can obtain rule declarations and match
conditions. Executing arbitrary Ruby actions would require trusting the
specification and would still cover only the inputs tried.

## Decision

Compare one rule selection at a time in each named lexical state. Compare the
selected body length, the static token type after keyword classification, the
channel, and literal state operations. Treat a skipped body and a position
with no matching rule as distinct outcomes.

Report the shortest distinguishing input by byte length. Include the byte
offset when the result needs a preceding input prefix. Report equality only
when the comparison covers the entire stated input domain. Report an
inconclusive result when the compiler cannot determine a relevant action or
the search cannot complete.

## Out of scope

Token values, arbitrary action code, and changes to later tokens belong to
runtime tests. Ordered first-match selection requires its own analysis of
regexp branch order.

## Alternatives considered

Comparing only the accepted body languages would miss changes to tie
breaking, trailing context, and keyword classification. Running a fixed set
of samples can show a difference but cannot establish equivalence for a
source rewrite.

## Consequences

A counterexample can be replayed at the reported offset in the named state.
A proven equality can support automated changes within the comparison
contract. A search across two large automata can reach the configured state
limit. A caller that requires a proof must handle the inconclusive result.
