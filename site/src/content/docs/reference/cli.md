---
title: CLI reference
description: Validate, inspect, and generate lexers from the command line.
---

The main commands are:

| Command | Purpose |
| --- | --- |
| `flexr check SPEC` | Parse and diagnose a specification |
| `flexr generate SPEC -o OUTPUT` | Write generated Ruby |
| `flexr trace SPEC INPUT` | Show automaton state, acceptance, and transitions |
| `flexr --help` | Print command and option help |

Use `check` in CI and treat warnings according to the compatibility policy of your project. `trace` describes DFA behavior; it is not an input-string logging command.

```sh
bundle exec flexr check examples/calculator/lexer.flexr.rb
bundle exec flexr generate examples/calculator/lexer.flexr.rb -o tmp/calculator_lexer.rb
```

For complete options, output formats, and exit status behavior, see the repository's [CLI reference](https://github.com/ydah/flexr/blob/main/docs/reference/cli.md).
