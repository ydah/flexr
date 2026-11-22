# ADR 0028: Compile absence groups as DFA difference

## Context

Ruby's `(?~X)` syntax can describe text that avoids a terminator or another
regular language. The generated lexer needs the same accepted language as
the runtime compiler, including character boundaries and empty matches.

## Decision

Let the universe be all strings of valid UTF-8 scalars or all byte strings
in binary mode. Compile `(?~X)` as the difference between that universe
and the language of a universe string, then `X`, then another universe
string. The DFA product treats a missing transition in the forbidden
language as a rejecting state. It retains only strings in the universe.
Minimize the product and insert it into the enclosing NFA so concatenation,
alternation, and longest-match selection continue to work normally.

Apply `max_dfa_states` when constructing each operand DFA, the product,
and the enclosing DFA. Classify empty matches from the language definition.
If the excluded language contains the empty string, the difference is empty.
Ruby regexp matching of a nullable excluded expression can instead return
an empty match, as in `\A(?~a?)\z` on Ruby 4.0.9.

Serialized artifacts use their existing DFA representation. The
`firstmatch` backend retains its Ruby regexp selection for rule bodies,
so use a longest-match backend for a body containing absence. Trailing
context already uses a DFA and supports absence.
