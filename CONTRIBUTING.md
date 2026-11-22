# Contributing

## Development setup

```sh
bundle install
bundle exec rake test
bundle exec rubocop
```

The runtime supports Ruby 3.1 and newer. Generator changes need Ruby 3.3 or
newer because Prism is used for source analysis.

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

Golden snapshots under `benchmark/golden/` preserve generated Ruby with the
compiler version and its derived digest normalized. The comparison includes
user code, artifact schema, runtime ABI, and Unicode data. Use
`bundle exec rake golden:update` after reviewing an intentional output change.
`generated:verify` checks that the committed tokenizer is reproduced exactly.

Markdown-only pushes and pull requests run documentation verification without
the test matrices or other Ruby checks. Changes limited to `site/` or its Pages
workflow skip Ruby CI and follow the Pages workflow's triggers. Changes that
also include code or Ruby configuration still run the full Ruby checks. The
daily scheduled runs retain all validation layers.

## Documentation changes

README is an entry point. Put task-oriented instructions in `docs/how-to/`,
exact contracts in `docs/reference/`, and design rationale in
`docs/explanation/`. Keep executable specifications in `examples/` and link to
them instead of duplicating large source blocks. `rake docs:verify` checks local
links, the tutorial example, CLI help, and stable DSL coverage.

All documentation in this repository is written in English.
