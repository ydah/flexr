# Deploy a standalone lexer

Use `--standalone` to embed the flexr runtime into the generated file:

```sh
flexr lexer.flexr.rb --standalone -o lexer_standalone.rb
```

The generated file removes `require "flexr"` and includes only the runtime
sources needed to execute its compiled tables. Compiler, generator, and
minimizer sources are omitted. The regexp reference matcher and Unicode tables
are included only when the selected backend or trailing context needs them. It
can be loaded by a Ruby process that does not have the flexr gem installed:

```sh
ruby -e 'load ARGV.fetch(0); p Lexer.new("12").tokens' lexer_standalone.rb
```

Generation still needs the flexr gem and Prism on Ruby 3.3 or newer. Runtime
execution needs the generated file and Ruby's standard library only.

Standalone output is larger and duplicates the runtime for every artifact.
Prefer ordinary generated output when several lexers share one application and
can depend on the flexr gem. The standalone behavior is covered by the CLI
end-to-end test.
