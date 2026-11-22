# ADR 0041: Insert indentation tokens after rule selection

## Context

In indentation-sensitive grammars, the parser needs tokens that mark entry
to and exit from a block. A block boundary depends on earlier line widths
and balanced brackets. The existing DFA selects individual rule matches.

## Decision

Configure the newline, indent, and dedent token types in the lexer DSL.
Record leading spaces and tabs before the runtime can discard the matched
bytes. Use default-channel newlines and original bracket lexemes to decide
when a line can change layout. Leave ordinary rule matching and token
actions on their existing path.

Emit synthetic tokens before the next visible rule token or at EOF. Queue
the scanned token behind those layout tokens. A checkpoint includes the
queue, the indentation widths, and the open brackets. Use a checkpoint for
nonzero positioning. Rewind to zero when layout needs to be read again.

Embed the layout processor in standalone artifacts only for lexers that
declare `indentation`. Keep the processor above any trivia-channel wrapper
so it uses the same visible token stream as the parser.
