# Generate a lexer

Generate a Ruby artifact from a `.flexr.rb` specification:

```sh
flexr path/to/lexer.flexr.rb -o path/to/lexer.rb
```

Generation is static by default. Prism reads the source, resolves supported
constant and expression forms, compiles the same DFA model used by runtime
mode, and replaces DSL calls with a compiled installation payload. Ordinary
Ruby constants, comments, requires, and non-DSL code remain in the file.

## Static expressions

The default path accepts regexp and string literals, arrays and hashes of
supported values, constants, ranges, interpolation whose values are static,
`.freeze`, and `Regexp.union`. Constants follow Ruby source order. A call whose value depends on runtime state raises
`FLEXR-E017`. See the [static-expression reference](../reference/generated-artifacts.md)
for the exact boundary.

## Dynamic specifications

```sh
flexr path/to/lexer.flexr.rb --eval -o path/to/lexer.rb
```

`--eval` executes the specification and is therefore limited to trusted build
inputs. It is useful when a pattern is assembled by a method or external
configuration, but it removes the static-analysis guarantee and can make the
artifact depend on the build environment.

## Reproducible builds

Commit generated files when downstream consumers should not need Prism, or
generate them in the build when the source is the only artifact you distribute.
The generated header records the source path, payload digest, Unicode snapshot,
backend, compilation mode, and standalone setting. Use the digest and
`generated:verify` in CI to detect stale committed output.
