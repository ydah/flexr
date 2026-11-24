# ADR: Treat CRLF as one atomic match for the line-break escape

- Status: Proposed
- Decision date: 2026-11-23
- Related: [20260809_leftmost_longest.md](20260809_leftmost_longest.md#decision), [20261123_derivative_dfa_construction.md](20261123_derivative_dfa_construction.md#decision)

## Context

Flexr 2.2.0 rejects `\R` and suggests an alternation with CRLF followed by
single-character line breaks. The suggested alternation works as a separate
longest-match token. In a larger pattern it gives a different result from
Ruby. For example, with Ruby 4.0.9, `\R\n` fails on one CRLF and succeeds on
CRLF followed by an additional LF. Ruby commits to the CRLF branch of `\R`
before it attempts the remainder of the pattern.
[Ruby 4.0 `node_linebreak` implementation](https://raw.githubusercontent.com/ruby/ruby/ruby_4_0/regparse.c)

## Decision

Match CRLF as one atomic line break. Match a lone CR only when the next byte
in the active input source is absent or differs from LF. A rule may need that
byte even when it falls outside the candidate token. Determine captures under
the same condition as the selected token.

Match CR, LF, vertical tab, and form feed in UTF-8 and binary mode. Match
U+0085, U+2028, and U+2029 in UTF-8.

## Alternatives considered

Use an ordinary CRLF-or-single-character alternation. That fits the existing
unconditional transitions, but it can split a CRLF pair to make a larger
pattern succeed. It changes the tokens for patterns such as `\R\n`.

## Consequences

Ruby line-break expressions retain their behavior when concatenated or
repeated. A streamed match can read one additional byte to resolve a CR.
That byte remains available to the next token if it falls outside the
selected match.
