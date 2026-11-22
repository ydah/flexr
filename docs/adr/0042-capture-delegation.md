# ADR 0042: Delegate a capture with its original source coordinates

## Context

A host grammar can recognize an embedded region and delegate its contents to
another lexer. Equal strings can occur at several points in a single match.
The host needs the selected group's byte offset to locate the child's tokens.

## Decision

Reuse the named capture replay and its byte offsets. Give the child a slice
of the accepted match and run its usual scanner, including its actions. The
parent retains its own cursor and state. Translate the child's positions
and report them in the host file. Share the parent's configured limits and
bound nested delegation.

Only publish staged tokens after the child scan succeeds. Drain them through
the usual consumption API before scanning a new host token. A parser adapter
can consume the same token pairs through `racc_next_token`.

Embed the optional runtime helper when the standalone lexer source calls
`delegate` or selects `option :delegation`. Compile the embedded grammar as
a separate artifact that can load against the host's runtime.
