# Migrate from flex

Use the importer to translate a flex `.l` file into a Ruby specification:

```sh
flexr import scanner.l -o lexer.flexr.rb
```

Common rules and actions are translated, including `return`, `BEGIN`,
`yyless`, `yymore`, and `ECHO`. The importer preserves header and footer text as
Ruby comments where possible. Run the result through `flexr check` before
loading it.

Untranslated C actions are emitted as `FLEXR-TODO`; the command returns status 1
and does not create or overwrite the requested output file. Complete the Ruby
action manually and repeat the check. Also review rule overlaps: flexr uses
longest-match semantics, which can differ from a flex specification that relies
on rule order.

The [CLI reference](../reference/cli.md) documents importer exit statuses and
the [errors reference](../reference/errors.md) documents `FLEXR-TODO` behavior.
