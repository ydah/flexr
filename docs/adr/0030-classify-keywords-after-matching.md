# ADR 0030: Classify keywords after rule selection

## Context

Reserved words often share the same lexeme language and token value as
identifiers. Declaring each as a rule adds paths to the automaton and makes
rule order part of the keyword lookup.

## Decision

Keep the identifier rule as the DFA candidate. A keyword table belongs to a
base `emit:` type. After a rule with that type wins, look up its exact
lexeme and use the mapped token type. The error policy, match length,
token value, location, and lexical state follow the winning rule.

Validate spellings against the base rules using the compiled DFA. For
`firstmatch`, the rule's first match must also consume the full spelling.
Require a declarative base type so generation and diagnostics can resolve it
statically. Register the base type and all mapped types for parser integration.

The generated artifact carries keyword tables as optional data. Generated
actions for participating rules perform the same lookup. Other generated
actions and ordinary runtime lexers keep their existing execution paths.
The tables leave DFA transitions and the generated artifact ABI unchanged.
