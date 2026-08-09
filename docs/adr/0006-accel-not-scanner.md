# ADR 0006: Acceleration is an optimization, not a matcher

Region acceleration may skip self-loop bytes, but the DFA remains the source
of truth. Acceleration can be disabled for equivalence tests.
