# ADR 0043: Expand reusable lexer rules explicitly

## Context

Source order decides ties between rules of equal length and priority.
Inheritance would make a rule's position depend on declarations in another
class.

## Decision

Define reusable rules in modules extended with `Flexr::Rules`. A consuming
lexer calls `use` at the position where those declarations belong. The
rules receive new indexes and the caller's active states. The existing
priority and channel behavior applies to each copy. Lexer subclasses start
with their own specification.

The static generator resolves a named rule-set module in the same source
file and reports argument or declaration locations for unsupported forms.
Generated actions retain their original Ruby blocks so their lexical
variables and constants behave as in runtime mode.

## Consequences

Static generation supports one direct declaration per rule-set module.
External rule sets and dynamically selected modules can be used with the
runtime lexer. Standalone generation includes rule-set support only when
the source declares such a module.
