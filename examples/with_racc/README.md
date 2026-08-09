# flexr with Racc

`RaccLexer` exposes `racc_next_token`, so a Racc parser can consume the same
lexer without an adapter. The example keeps the parser dependency optional;
run `flexr tokens` to compare its token names with a parser's `%token` list.
