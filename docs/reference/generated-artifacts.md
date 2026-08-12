# Generated artifacts

## Dependency matrix

| Use | Build-time requirement | Runtime requirement |
|---|---|---|
| Runtime mode | None beyond the flexr gem | `flexr` gem |
| Normal generated mode | flexr gem and Prism on Ruby 3.3+ | `flexr` gem |
| Standalone generated mode | flexr gem and Prism on Ruby 3.3+ | Generated file and Ruby standard library |

The runtime gem supports Ruby 3.1 and newer. The generator's Prism path is
supported on Ruby 3.3 and newer. A generated file can be loaded by a compatible
runtime without the generator installed.

## Static evaluation boundary

The default generator resolves:

- regexp, string, numeric, symbol, and range literals;
- arrays and hashes made from supported values;
- constants in lexical and qualified scope;
- interpolation whose expressions resolve statically;
- `.freeze` on a static value; and
- `Regexp.union` with static arguments.

Methods with runtime-dependent results, `Time`, IO, environment reads, and
arbitrary dynamic calls produce `FLEXR-E017`. `--eval` is the explicit escape
hatch and executes the complete specification.

Constants are resolved in source order, array splats are flattened with Ruby
semantics, and regexp interpolation retains the embedded regexp's options.
Receiver-qualified DSL calls, DSL hidden in conditionals or other unsupported
control flow, unknown DSL keywords, and files containing multiple candidate
lexer classes fail closed with `FLEXR-E017`. A file intended for static
generation should contain one lexer class and place DSL statements directly in
that class or a `state`/`all_states` body.

## Source transformation

The generator removes DSL call spans, inserts `Flexr::Generated.install_compiled!`,
and adds generated scanner methods. Source edits use Prism spans, so heredocs and
the `__END__` data section are not rewritten. User actions remain Ruby source. A generated
header records:

- source path;
- SHA-256 digest of the generated payload;
- artifact schema and runtime ABI versions;
- vendored Unicode version;
- effective backend;
- whether compilation used eval; and
- whether the runtime is standalone.

Do not edit generated files by hand. Regenerate them when the specification,
generator, backend, table format, or Unicode snapshot changes.

Compiled payloads also record the artifact schema, compiler version, runtime ABI,
and Unicode version. Loading fails with `FLEXR-E020` when those contracts are
missing or incompatible. This prevents a stale artifact from silently running
against a runtime with different table or Unicode semantics.

Generation refuses to write through the input path, including aliases made with
symbolic or hard links. Outputs are written to a file in the destination directory,
synced, and atomically renamed. An unchanged output is left untouched so build
timestamps remain stable. For input names other than `*.flexr.rb`, the default
output is `*.generated.rb`.

## Table formats

`--table-compression none|rows|full` controls row packing. `--table-format
literal|packed` controls whether packed arrays are emitted as Ruby literals or
Base64. Packed artifacts retain and query their packed representation; the
dense row view is populated lazily only when an inspection API requests a row.
These settings affect artifact size and loading cost, not matching semantics.

Standalone output embeds a runtime core, not the compiler or generator. The
regexp reference matcher and vendored Unicode tables are added only for a
`firstmatch` backend or trailing-context rules that can use that matcher.
