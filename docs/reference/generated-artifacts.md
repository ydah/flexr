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

## Source transformation

The generator removes DSL call spans, inserts `Flexr::Generated.install_compiled!`,
and adds generated scanner methods. User actions remain Ruby source. A generated
header records:

- source path;
- SHA-256 digest of the generated payload;
- vendored Unicode version;
- effective backend;
- whether compilation used eval; and
- whether the runtime is standalone.

Do not edit generated files by hand. Regenerate them when the specification,
generator, backend, table format, or Unicode snapshot changes.

## Table formats

`--table-compression none|rows|full` controls row packing. `--table-format
literal|packed` controls whether packed arrays are emitted as Ruby literals or
Base64. These affect artifact size and loading cost, not matching semantics.
