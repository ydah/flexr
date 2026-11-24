# Changelog

Notable changes to flexr, newest first. Release dates use Japan Standard Time
(UTC+09:00).

## Unreleased

## [2.3.0](https://github.com/ydah/flexr/compare/v2.2.0...v2.3.0) - 2026-11-25

### Added

- Regexp rules support positive and negative lookahead and lookbehind, `\b` and `\B`, and `^`, `$`, `\A`, `\z`, and `\Z` inside rules. Assertions use the active source across chunk boundaries. Lookbehind cannot see into a parent input paused by `push_input`.
- Use `\R` for line breaks, including atomic CRLF, and `\X` for extended grapheme clusters. Regexp rules also accept octal escapes, including multibyte UTF-8 sequences and binary bytes.
- Set `state(:raw, match: :shortest)` to select the shortest eligible token body in a lexical state. The next token can still read the trailing context.
- Feed chunks as they arrive with `Lexer.push`, `feed(bytes)`, and `finish`. Chunks can end inside a token, a UTF-8 character, or trailing context.
- Use `Lexer.incremental` and `document.relex(edit)` to update token streams after byte-range edits. Flexr reuses tokens where it can verify the surrounding context and falls back to a full scan for opaque actions by default.
- Use `Lexer.parallel_tokens` to scan large Strings with Ractors on CRuby 4.0.6 and later. Eligible table and direct lexers use declarative `emit:` and `skip:` rules. Other configurations use serial scanning.
- Generate Lrama parser-state token masks with `flexr generate --lrama-grammar` and use them with `next_token(parser_state:)`. `flexr check --lrama-grammar` reports tied terminals with a witness and a grammar state path.
- Use `flexr diff` to find the shortest input that changes rule selection, including comparisons between longest-match and `firstmatch` lexers. RSpec and Minitest helpers can check language inclusion, overlap, and equivalent rule selection with counterexamples.
- Collect DFA transition coverage from lexer tests. Reports include a shortest input and scan offset for an uncovered transition when one is reachable.
- Read valid continuation bytes and the shortest completion from `Flexr::LexError#continuation` for DFA lexical errors. The diagnostic points to the mismatching byte or EOF.
- Inspect DFA backup bounds with `flexr explain`, `trace`, or `dot`. `flexr check --warn all` can report a repeatable input for unbounded backup, and `--residuals` shows what longest-match rules can still match.
- Set `Flexr.cache_dir` to reuse compiled DFA tables across Ruby processes. Set it to `nil` to disable the cache.
- Pass representative input files with `flexr generate --profile GLOB` to tune the generated DFA scanner while preserving its token stream.
- Use `flexr generate --standalone --target-ruby 2.5` or `--target-ruby 3.0` to ship static DFA lexers for those versions without installing flexr on the target machine. The gem and generator still require Ruby 3.4 or later.
- Use `flexr export SPEC --to rouge` to generate a `Rouge::RegexLexer` from supported static rules. Use `--token-map` to map token kinds and channels. If Rouge would select a different match, export stops with a witness and the relevant rule location.

### Changed

- Longest-match scanners reuse failed scans to avoid quadratic rescanning on overlapping rules such as `/a/` and `/a*b/` over a run of `a`. Regenerate existing lexers to pick up the scanner optimization.
- Runtime table and direct lexers build uncached DFA transitions on demand, and UTF-8 property rules use prebuilt automata. The DFA state limit can now be reported during scanning, even if lexer construction succeeded.
- Longest-match scanners track supported named captures and `followed_by:` boundaries during scanning. Named captures that exceed the tagged DFA limits continue to use regexp replay and produce an informational diagnostic.
- `flexr fix` checks rule selection before saving an edit. It shows a shortest counterexample if selection changes and asks for approval when a fix changes behavior or cannot be verified.

### Fixed

- Preserve ordered `firstmatch` alternatives and greedy repetition across chunk boundaries when Flexr can compile an ordered matcher. Regenerate existing `firstmatch` lexers to get the fix.
- Reject overlong UTF-8, surrogate encodings, and out-of-range code points when matching broad Unicode ranges.

### Upgrade notes

- `Lexer.new` and `push_input` now take a frozen snapshot of mutable Strings. If the lexer needs to see later changes to the caller's String, pass `freeze_input: false`.
- Deploy newly generated non-standalone lexers with the flexr 2.3 runtime when using the new scanner features. Standalone files embed the runtime.

## [2.2.0](https://github.com/ydah/flexr/compare/v2.1.0...v2.2.0)

### Added

- Read named regexp groups from `captures` in a rule action. Delegate a
  capture to another lexer with `delegate(ChildLexer, capture: :name)` while
  preserving the child tokens' locations in the parent source.
- Match a compiled DFA at a byte offset with `Lexer.recognizer` without
  running rule actions. Use `checkpoint`, `restore`, and `seek` to resume
  a lexer between token reads.
- Pass `expect:` to `next_token` or `racc_next_token` to let the parser
  restrict eligible token rules for the current read.
- Emit indent and dedent tokens for indentation-sensitive languages, pause
  the current source with `push_input` to scan an included file, and read
  runtime delimiters with `scan_until` or `scan_until_line`.
- Reuse named lexer rule sets with `use`, including in lexical states.
- Preview and apply supported diagnostic fixes with `flexr fix`. Ruby LSP
  offers the same fixes and adds state navigation, token symbol completion,
  and a rule and state outline for `.flexr.rb` files.
- Generate shortest inputs for DFA transitions with `flexr skeleton` and
  optionally verify scanner parity across runtime, generated, and standalone
  modes. Start a Racc or Lrama project with `flexr new --parser`.
- Import supported oedipus_lex `.rex` declarations with
  `flexr import --from oedipus_lex`, preserving first-match rule order.
- Try indentation, heredoc, and embedded JavaScript in the Playground when
  its runtime supports them. Copy a GitHub issue draft with the exact
  specification, input, runtime version, and diagnostics from a run.

### Upgrade notes

- Generated lexers using named regexp captures or lexer delegation require
  flexr 2.2 or later at runtime. Standalone files include their runtime.

## [2.1.0](https://github.com/ydah/flexr/compare/v2.0.0...v2.1.0)

### Added

- Use `(?~X)` in DFA rules to match text containing no substring matched
  by `X`. For example, `%r{/\*(?~\*/)\*/}` matches a C-style comment.
- Reuse named patterns across rules and combine them with alternatives,
  concatenation, intersection, difference, and complement. Use `upto` to
  consume through the first match of a terminator.
- Use `keywords` to turn exact identifier spellings into keyword tokens after
  the identifier rule matches. A longer identifier such as `ifx` still emits
  the identifier token.
- Retain comments and whitespace in named token channels for source tools.
  Collect them in input order with `tokens(channels: :all)` or read
  `leading_trivia` on structured tokens. Default iteration and parser token
  streams still return only default-channel tokens.
- Set `priority:` to break ties between equal-length DFA matches. Rules with
  equal priority continue to use source order.
- `flexr check` can flag shadowed keyword spellings and suggest replacing
  consecutive literal rules with a keyword table. With `--warn all`, it can
  also suggest `emit:` for simple emission blocks.

### Changed

- DFA scanning allocates fewer temporary objects. Regenerate lexer files to include the updated scanner paths.
- Generated lexers that use token channels or nonzero rule priorities require
  the Flexr 2.1 runtime. Standalone files include their runtime.

## [2.0.0](https://github.com/ydah/flexr/compare/v1.1.0...v2.0.0) - 2026-11-22

### Added

- A real Ruby WASM Playground with editable specifications, diagnostics, DFA
  diagrams, trace steps, generated code, presets, and share links.
- Input tracing with candidate lengths, rule priority, actions, state changes,
  and human or JSON output for runtime and generated scanners.
- Optional phase profiling and isolated interpreter, YJIT, and ZJIT comparisons.
- RSpec and Minitest token assertions with explicit-update token snapshots.
- Grammar token validation with `check --grammar` and Lrama declaration export.
- Ruby LSP diagnostics and rule hovers for unsaved lexer specifications.
- Public API RBS signatures and typed consumer checks.
- TOML, GraphQL, and SQL subset examples with benchmarks and parity checks.
- A migration guide and static `check --target 2.0` impact reporting.
- Explicit `accel :strscan` whole-token acceleration for proven ASCII paths.
- Opt-in Ractor sharing of generated method-action tables; unsupported closures,
  EOF blocks, and firstmatch reference caches are rejected explicitly.

### Changed

- Require Ruby 3.4+ for runtime, generation, and standalone artifacts.
- Make structured tokens and locations immutable `Data` records while retaining
  attribute readers and read-only indexing. Replace field mutation with `with`.
- Reject unknown `error_mode` values during initialization.
- Use artifact schema 2 and runtime ABI 2; regenerate v1 lexers after upgrading.
- Stabilize explicit firstmatch selection while retaining longest-match defaults.
- Reduce temporary Range allocations and use direct emit declarations in the
  JSON example without changing its tokens.

### Fixed

- Preserve UTF-8 source when generating lexers with Unicode action literals and surrounding constants.
- Show source context and installation guidance when Prism cannot load.
- Identify the installing file for incompatible generated artifacts when available.

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
