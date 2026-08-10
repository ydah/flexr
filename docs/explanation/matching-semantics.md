# Matching semantics

flexr implements leftmost-longest matching. At the current byte position, the
automaton records every accepting rule reached while scanning forward. The
last accepting position is the candidate token end. The rule with the smallest
source index wins when several candidates end at that position.

This is why `==` beats `=` regardless of which rule is written first, while two
same-length alternatives use definition order. A rule's `followed_by:` context
extends the selection end without extending the consumed token end.

The matcher is byte-oriented so binary input and invalid UTF-8 have deterministic
behavior. UTF-8 patterns still require valid codepoint boundaries before a
match is accepted. The runtime and generated scanner share the compiled model;
acceleration may skip self-loop bytes but cannot change the winner.

`firstmatch` is intentionally separate. It picks the first rule that has a
matching alternative and therefore is useful only for compatibility migrations
that accept the semantic difference. It is experimental and guarded by a
differential check during generation.
