# ADR 0038: Resolve named captures over the winning rule body

## Context

A byte-oriented DFA can recognize a named group like an ordinary group.
It cannot recover how the selected match divides text among groups when
several paths accept the same input.

## Decision

Keep groups transparent in DFA compilation and remember which pattern
supplied the selected match. For longest-match scanners, replay that
pattern with Ruby's regexp engine between absolute anchors on the body.
Use the same character classes and Unicode data used to compile the DFA.
Firstmatch already has Ruby match data and can use that directly.

Expose a frozen hash in the action. The values describe the body before
action controls change the token span. Replay runs only when the action
reads `captures`. It preserves Ruby's rules for selecting among ambiguous
group spans while retaining flexr's longest-match rule and position tracking.

Generated scanners carry replay expressions only for patterns with named
groups. Artifacts with that metadata check the runtime's capture support.
