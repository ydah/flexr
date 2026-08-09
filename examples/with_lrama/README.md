# flexr with Lrama

The generated lexer exposes the same `racc_next_token` protocol used by
Lrama-generated parsers. Keep grammar token names in `emits` and verify them
with `flexr tokens` during the build.
