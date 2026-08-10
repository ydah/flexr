# Migrate from Rexical

Import a Rexical specification with:

```sh
flexr import scanner.rex -o lexer.flexr.rb
```

Rexical uses first-match semantics while flexr uses longest-match semantics.
The importer reports that semantic boundary and searches for concrete
counterexamples when it finds overlapping rules. Treat every reported witness
as a migration review item.

After rewriting actions and reviewing overlaps:

```sh
flexr check lexer.flexr.rb --warn all
flexr lexer.flexr.rb -o lexer.rb
```

Do not enable `backend :firstmatch` merely to hide a migration difference. It
is experimental, requires `option :experimental`, and generation performs a
differential check against the table matcher.
