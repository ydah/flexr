# ADR 0033: Match one rule at an absolute byte offset

## Context

Parser integrations need to recognize a rule in an existing string without
managing a second input cursor or executing lexer actions. Sharing the
compiled automaton keeps rule selection consistent across runtime and
generated lexers.

## Decision

Expose `Lexer.recognizer` as a shareable snapshot of one compiled lexical
state. Keep the DFA, lookahead machines, and fixed rule identities in the
snapshot. Materialize lazy generated transition rows during construction.
This makes the snapshot shareable independently of the lexer class and its
actions.

Use longest-match selection with trailing context, line anchors, and subject
encoding. Return the body end and the static `emit:` symbol when one exists.
Use the source-rule index for dynamic, skip, and default actions. The
recognizer computes rule identity before emission, including keyword
classification. Native `firstmatch` uses Ruby regexp alternative order and
raises an explicit error at recognizer construction.

Keep scan positions on the stack and expose a block form in addition to the
convenience tuple. A warmed Ruby 4.0.9 run measured 100,000 allocations
for 100,000 successful tuple calls. The same measurement recorded zero
allocations for block calls with ASCII, multibyte, and trailing-context
matches.

Include the native scanner helpers in `firstmatch` standalones. An ordinary
DFA standalone fixture with the recognizer used 90,990 bytes after separating
the helpers, compared with 102,424 bytes when it included them.
