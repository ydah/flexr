# Contributing

## Development setup

```sh
bundle install
bundle exec rake test
bundle exec rubocop
```

The runtime and generator require Ruby 3.4 or newer.
The generator uses Prism for source analysis.

## Validation layers

Run the focused test first, then the relevant contract checks:

```sh
bundle exec rspec spec/cli_spec.rb
bundle exec rake docs:verify
bundle exec rake modes:equivalence generated:verify golden:verify
bundle exec rake test:differential fuzz
```

The CI workflows also check Unicode invariants, acceleration equivalence,
generated-only loading, Graphviz output, coverage, and benchmark regressions.
Do not update a generated golden file to hide a semantic change; inspect the
generated diff and update the compatibility documentation when the change is
intentional.

Golden snapshots in `benchmark/golden/*.rb` contain generated Ruby with only
the compiler version and its derived digest normalized. Scanner code, user
literals, artifact schema, runtime ABI, and Unicode metadata remain part of
the comparison. A release version bump alone does not change these snapshots.
Generator safety tests separately check the real compiler version, digest,
and exact reproduction of committed generated artifacts.

On a mismatch, `golden:verify` prints a source diff and saves the actual snapshot
under `tmp/golden/`. Review that diff before accepting an intentional generator
change with `bundle exec rake golden:update`, then review the committed snapshot
diffs. Verification never updates the expected snapshots.

Changes to Ruby code or configuration run runtime and generator checks on
Ruby 3.4 and 4.0 across Linux, macOS, and Windows. Runtime checks also exercise
YJIT on Linux. Daily runs add Ruby head and macOS YJIT to the matrix.
The Ubuntu Ruby 4.0 interpreter job runs the suite with the 95% coverage
gate. The runtime and generator jobs run the full example verification tasks.
Those workflows skip changes limited to Markdown and the product site.

## Replay a verification mismatch

`test:differential` and `fuzz` save the first mismatch in
`tmp/verification-failures/` and exit with status 1.
The differential-fuzz workflow splits the seeded fuzz cases across three jobs.
To run one shard locally, set `FLEXR_FUZZ_SHARD` to a zero-based `INDEX/TOTAL`,
such as `2/3`. Each job attaches any saved failures as a
`verification-failures-<index>` artifact.
Replay one case from the repository root.

```sh
FLEXR_FAILURE_CASE=path/to/failure.json bundle exec rake verification:replay
```

The JSON records the commit, a fingerprint of the tracked diff and non-ignored
untracked files, Ruby and gem versions, seed, case number, comparison settings,
and both outcomes. For fuzz cases it also records the lexer path and its SHA-256.
The input is stored as hex with its original encoding, including invalid UTF-8.

Replay uses that exact input and runs the same comparison on the current
checkout. It reports drift in the fuzz lexer specification and exits with
status 1 if a mismatch persists or the comparison cannot run.
Before fixing a mismatch, record the base commit, expected behavior, and
validation commands in the task notes. Turn the mismatch into a focused
regression test that fails before the fix. Run it again after the fix with
the relevant validation layers and record the results.

## Documentation changes

README is an entry point. Put task-oriented instructions in `docs/how-to/`,
exact contracts in `docs/reference/`, and design rationale in
`docs/explanation/`. Keep executable specifications in `examples/` and link to
them instead of duplicating large source blocks. `rake docs:verify` checks local
links, the tutorial example, CLI help, and stable DSL coverage.

Write all documentation in English. Use the [ADR guide](docs/adr/README.md)
to decide when to record a decision and when to write an
[implementation record](docs/implementations/README.md).
