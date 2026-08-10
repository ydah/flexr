# Migration

First-match tools and flexr have different semantics. Review overlapping rules
after converting a specification; flexr will choose a longer match.

`flexr import` translates common flex actions such as `return`, `BEGIN`,
`yyless`, `yymore`, and `ECHO`. C actions it cannot translate are emitted as
`FLEXR-TODO` and the command exits unsuccessfully, so an incomplete import is
never reported as a finished migration. Rewrite those actions in Ruby and run
the generated specification through `flexr check` before using it.
