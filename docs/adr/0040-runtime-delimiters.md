# ADR 0040: Scan action-defined delimiters in the lexer runtime

## Context

Tagged heredocs and raw strings specify their delimiter in the source.
A rule can recognize the opener and determine its closing text at run time.

## Decision

Allow a matched rule's action to scan from its current byte position with
`scan_until` or `scan_until_line`. Track a matching delimiter prefix while
reading the existing streaming buffer so a delimiter can span chunks. Line
mode accepts a complete LF, CRLF, or EOF-terminated line at the beginning of
that line. Both methods enforce the lexer's resource limits.

Commit the cursor and match end after finding the delimiter. Return the
body before it. The regular token finalization updates coordinates for the
extended match and preserves the existing behavior of `less` and `more`.
Return `nil` at EOF if no delimiter matched, leaving the current match intact.
The action can decide whether to call `error!`.

Keep delimiter search in a standalone runtime helper. Embed it when the
grammar directly calls either method or selects `option :dynamic_delimiters`.
