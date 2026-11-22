# Migrating to flexr 2.0

This guide describes how to upgrade to flexr 2.0. The 1.2 release line offers
opt-in deprecation warnings while keeping the 1.x runtime contracts.

Run static checks before upgrading:

```sh
flexr check lexer.flexr.rb --target 2.0
flexr check lexer.flexr.rb --target 2.0 --format json
RUBYOPT=-W:deprecated ruby application.rb
```

`--target 2.0` reports the new requirements and identifies structured-token
declarations. It includes migration advice even when ordinary compiler
warnings are disabled with `--warn none`. `--warn-as-error` fails for migration
warnings. The mode uses the static reader and cannot be combined with `--eval`.
It does not execute the specification or scan consumer files, dependencies,
or metaprogramming; a clean result does not prove the application is ready.

## Ruby version

Use Ruby 3.4 or newer for the runtime, generator, and standalone lexers. Upgrade
deployment images and development tools before upgrading flexr. Loading v1 on
an older Ruby emits a notice when deprecated-category warnings are enabled.

## Immutable tokens and locations

With `token_kind :struct`, tokens and locations become `Data` records. The
option name stays `:struct` to avoid changing lexer declarations. Attribute
readers, keyword construction, and read-only indexing remain available.
Field setters, `[]=`, and checks that require a `Struct` instance must change.
The default array token format is unaffected.

Replace mutation with a new value:

```ruby
# Before
token.value = replacement

# After upgrading to v2
token = token.with(value: replacement)
```

Use attribute readers or `to_h` rather than relying on Struct-specific
enumeration or the raw storage of lazy location columns. Column readers
remain available without retaining the lexer. Immutability is shallow: a
mutable object emitted as a token value remains the application's responsibility.
When deprecated-category warnings are enabled, v1 warns on record field
assignments and `[]=` calls. It does not detect mutations of nested values or
every Struct mutator, so inspect consumer code and tests as well.

## Error policy

Only `error_mode: :raise`, `:token`, and `:panic` are valid in v2. An unknown
value raises `ArgumentError` during initialization, including for empty or
otherwise matching input. v1 warns at initialization when deprecation warnings
are enabled, while preserving its existing fallback behavior.

## Generated artifacts

Regenerate every lexer with the new generator after upgrading. Artifact schema
and runtime ABI change to version 2; loading an incompatible old artifact
produces `FLEXR-E020` with regeneration guidance. Standalone artifacts bundle
their runtime, so regenerate them as part of deployment as well. v1 reports an
opt-in warning when loading an ABI 1 artifact. Do not edit artifact metadata by
hand to bypass compatibility checks.

## Backends

`firstmatch` remains available with its explicit first-matching-rule semantics;
it does not acquire the longest-match behavior of `table`, `direct`, and `auto`.
No backend removal is required by this migration.
