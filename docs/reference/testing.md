# Testing lexers

The helpers consume the complete input and compare the returned tokens. They
work with runtime and generated lexer classes, and forward keyword options to
the lexer constructor. Install the test framework separately; requiring `flexr`
does not load either framework.

## RSpec

```ruby
require "flexr/rspec"

expect(Lexer).to tokenize("12 + 3").as([
  [:INTEGER, 12], [:PLUS, "+"], [:INTEGER, 3]
])
```

Use `.as` to compare token values exactly, including symbol/string distinctions.
Lexer errors propagate so that tests can use the usual `raise_error` matcher.

## Minitest

```ruby
require "minitest/autorun"
require "flexr/minitest"

class LexerTest < Minitest::Test
  include Flexr::Minitest::Assertions

  def test_numbers
    assert_tokenize Lexer, "12", [[:INTEGER, 12]], chunk_size: 1
  end
end
```

## Token snapshots

Store snapshots in a directory owned by the test suite. Snapshot assertions
fail if the file is missing or differs. They write files only when the call
explicitly passes `update: true`; review the resulting diff before committing.

```ruby
expect(Lexer).to tokenize("12 + 3").matching_snapshot("spec/snapshots/sum.json")
assert_token_snapshot Lexer, "12 + 3", "test/snapshots/sum.json"
```

To create or replace a snapshot, temporarily add `update: true` to
`matching_snapshot` or `assert_token_snapshot`, then remove it for normal tests.
Create the parent directory first.

Snapshots use deterministic JSON, preserving symbols and non-UTF-8 bytes with
tags. Hash entries are sorted by their serialized keys, so insertion order
does not affect the snapshot. Supported values are nil, booleans, finite
numbers, strings, symbols, arrays, hashes, `Flexr::Runtime::Token`, and
`Flexr::Runtime::Location`. Convert custom token values to these types before
snapshot testing. Snapshot strings compare content rather than Ruby encoding
tags, allowing ASCII strings from String and IO input to use the same file.
