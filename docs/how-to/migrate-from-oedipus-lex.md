# Migrate from oedipus_lex

Select the source format explicitly because both Rexical and oedipus_lex use
`.rex` files.

```sh
flexr import lexer.rex --from oedipus_lex -o lexer.flexr.rb
flexr check lexer.flexr.rb
```

The generated specification uses `backend :firstmatch`. Rules retain their
source order, and alternatives within a regexp retain Ruby's matching order.
Compare the old and new token pairs on your inputs before switching parsers.

## Supported forms

The importer accepts one lexer class in a UTF-8 file. It handles
slash-delimited regexps with no flag, `/i`, or `/o`, and interpolation of
previously declared regexp macros such as `/#{NUMBER}/`. A rule without
an action skips its match. So do the blocks `{ nil }` and `{ next }`.

A one-line action can return `[kind, value]`. The kind can be a symbol,
string, or `text`. The value can be a literal, `text`, or a call to
`text.to_i`, `text.to_f`, or `text.to_sym` without arguments.

Unsupported input produces line-specific diagnostics and exits with status
`1`. Use the reported lines to identify code that needs to move or change.
The importer writes output only after the whole input passes validation.

## Trial against ruby_parser

The `lib/ruby_lexer.rex` shipped with
[ruby_parser 3.22.0](https://rubygems.org/gems/ruby_parser/versions/3.22.0)
uses 88 rules, including 64 inside 15 guard groups. The native generator
also reports 13 regexp macros, 12 predicates, and 35 method actions. The
lexer enables `lineno` and `column` and runs a six-line `start` hook for each
token. The trial produced 111 diagnostics and left the output path empty.

A manual port needs to preserve the prefix guards and parser-dependent
state, then rewrite the actions and coordinate their input positions with
Flexr's runtime. The
[oedipus_lex rules reference](https://docs.seattlerb.org/oedipus_lex/)
describes these source constructs.
