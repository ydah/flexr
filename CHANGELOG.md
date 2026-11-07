# Changelog

Notable changes to flexr, newest first. Release dates use Japan Standard Time
(UTC+09:00).

## [1.1.0](https://github.com/ydah/flexr/compare/v1.0.0...v1.1.0) - 2026-08-13

### Added

- Runtime limits for lookahead, retained buffer size, and scanning steps, plus a
  cancellation callback. `retain_input: false` discards consumed input so
  streaming lexers can keep a sliding buffer.
- Regexp support for open repetition (`{n,}`), character-class intersection
  (`&&`), trailing hyphens in classes, and hexadecimal classes (`\h` and `\H`).
- Explicit `flexr/runtime`, `flexr/generator`, and `flexr/cli` entry points.
  `require "flexr"` loads build tools lazily.

### Changed

- Unicode properties and POSIX classes now compile into the DFA, using the
  same vendored Unicode 15.1.0 data for longest-match selection.
- Compiler construction and minimization avoid repeated work. Generated
  scanners use state-specific fast paths, and token locations track positions
  incrementally instead of rescanning consumed input.
- Packed tables and the `direct` backend avoid retaining duplicate transition
  tables. The `auto` backend selects a representation using estimated table
  size and lookup cost.

### Fixed

- Aligned action precedence, nested state membership, and structured errors
  across runtime, generated, and standalone modes.
- Static generation preserves heredocs and `__END__` data, resolves constants
  in source order, and retains interpolated regexp options. Unsupported DSL
  control flow and ambiguous lexer classes are rejected with `FLEXR-E017`.
- Generation refuses to overwrite its input, including symlink and hard-link
  aliases. Output writes are atomic and leave unchanged files untouched;
  non-`.flexr.rb` inputs default to a separate `.generated.rb` output.
- UTF-8 `less` and empty-match handling respect codepoint boundaries.
  Token limits apply before actions run, and non-progressing scan cycles raise
  a diagnostic instead of looping indefinitely.

### Upgrade notes

- Regenerate lexer artifacts when upgrading from v1.0.0. Generated files now
  record schema, runtime ABI, compiler, and Unicode versions; missing or
  incompatible metadata raises `FLEXR-E020`.
- The retained input buffer now defaults to a 64 MiB limit. Adjust
  `max_buffer_size` when retaining larger inputs, or use `retain_input: false`
  for streaming lexers that can discard consumed prefixes.
- Specifications become immutable after compilation. Later DSL changes raise
  `Flexr::FrozenSpecificationError`; unknown option names and conflicting state
  declarations are rejected immediately.
- Unknown alphabetic regexp escapes are rejected instead of treated as
  literals. Unknown `on_error` callback results raise
  `InvalidRecoveryActionError` instead of falling back to the default policy.
- `firstmatch` remains experimental. Runtime and generated modes share its
  rule-order behavior; differences from longest-match behavior produce
  `FLEXR-W010` instead of aborting generation.

## [1.0.0](https://github.com/ydah/flexr/tree/v1.0.0) - 2026-08-11

Initial release.

### Added

- A pure Ruby lexer DSL with deterministic longest-match selection and source
  order as the tie-breaker, available in runtime and generated modes.
- Static source generation with Prism, standalone output that does not require
  the flexr gem, and a Rake task for generating lexers during builds.
- Lexical states, trailing context, EOF actions, token locations, streaming IO,
  UTF-8 and binary input, and Unicode 15.1.0 property data.
- Stable `table`, `direct`, and `auto` backends, optional scanner acceleration,
  packed tables, and an experimental `firstmatch` backend.
- CLI diagnostics, rule and DFA inspection, Graphviz output, benchmarks, and
  import tooling for flex and Rexical specifications.
- Calculator, JSON, toy-language, Ruby-subset, Racc, and Lrama examples.

Runtime requires Ruby 3.1 or newer. Generation requires Ruby 3.3 or newer with
Prism available.
