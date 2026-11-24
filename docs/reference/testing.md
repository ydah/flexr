# Testing lexers

Token assertions consume the complete input and compare the returned tokens. They
work with runtime and generated lexer classes, and forward keyword options to
the lexer constructor. Install the test framework separately. Requiring
`flexr` leaves both frameworks unloaded.

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

## Language assertions

Use language assertions to check properties across all inputs in the comparison
domain. A failed comparison reports a shortest counterexample when it finds one.
Language assertions use the compiler from a standard Flexr library load.

```ruby
require "flexr/rspec"

expect(Lexer).to have_disjoint_tokens(:INTEGER, :KEYWORD).in_state(:initial)
expect(Lexer.pattern(/[0-9]+/)).to include_language(Lexer.pattern(/[0-9]{2}/))
expect(LexerV2).to tokenize_like(LexerV1).in_state(:initial)
```

- `have_disjoint_tokens` checks whether rules for the two token kinds can accept
  the same span in the same source before the backend chooses a winner. It
  applies left and right assertions, trailing context, and keyword remapping.
  The failure shows the source and starting byte offset. Use `emit:` to
  declare the kinds that the assertion can compare. For `firstmatch`, the
  assertion considers the language of each compiled pattern.
- `include_language` compares complete strings, including the empty string.
  It accepts pattern values, regexps, and literal strings. The receiver is the
  superset. The default encoding is UTF-8. Pass `encoding: Encoding::BINARY`
  for a byte language. Use `unicode: true` for Unicode shorthand classes.
- `tokenize_like` uses the rule-selection comparison from `flexr diff` for one
  lexical state. It compares the selected body length and declared effects, such
  as the token kind and channel. It compares runtime and generated lexers
  without running rule actions.

Both lexer assertions default to `:initial`. A comparison that reaches its
search limit or encounters a rule it cannot model reports why it is
inconclusive. Inconclusive comparisons fail both positive and negated RSpec
expectations. Use a token assertion with a concrete input to compare values
produced by Ruby actions.

For Minitest, include `Flexr::Minitest::Assertions` and use
`assert_disjoint_tokens Lexer, :INTEGER, :KEYWORD`,
`assert_includes_language superset, subset`, or
`assert_tokenize_like LexerV2, LexerV1, state: :initial`.

## DFA transition coverage

Share a coverage collector across test inputs for one runtime, generated, or
standalone lexer class.

```ruby
require "flexr/testing"

coverage = Flexr::Testing::Coverage.new(Lexer)
expect(coverage.lexer("12 + 3").tokens).to eq([
  [:INTEGER, 12], [:PLUS, "+"], [:INTEGER, 3]
])

report = coverage.report
puts "#{report.fetch(:covered)}/#{report.fetch(:total)} transitions covered"
```

Each transition records the lexical state, source and target DFA states,
byte class, and hit count. The collector runs the returned lexer through
the DFA interpreter. Transitions explored while trying a longer token
count even when the lexer later selects a shorter token or raises an error.
To check the native generated scanner's tokens, use a separate token assertion.
For example, a UTF-8 lexer with both a raw byte rule and a line anchor can
return different tokens in the interpreter and the generated scanner.

The collector follows the lexer's input stack. A delegated child runs in a
separate lexer instance, and trailing-context checks use separate automata.

`report[:uncovered]` contains the unvisited edges. When the skeleton can find
a valid source, the edge includes `example: {input:, offset:}` with the
shortest source in bytes and the byte offset where the scan starts. Replay an
example in the reported lexical state.

```ruby
if (edge = report.fetch(:uncovered).find { |entry| entry.key?(:example) })
  example = edge.fetch(:example)
  scanner = coverage.lexer(example.fetch(:input), error_mode: :token)
  scanner.begin_state(edge.fetch(:state))
  scanner.seek(example.fetch(:offset))
  scanner.next_token
end
```

An example reaches the edge during that scan. It may end with an unmatched
input error. Indentation lexers allow `seek` only at byte 0. For a nonzero
offset, make the prefix tokenizable and advance through it in the test.
An edge without an example has a reason such as
`:no_valid_input` when no valid UTF-8 source reaches the edge.
Coverage applies to DFA backends. `firstmatch` uses ordered regexp matching.
