# regexp_parser scanner experiment

The [experimental Flexr scanner](../../benchmark/regexp_parser_scanner.rb)
uses exclusive states and the state stack for nested character sets, named
captures to classify POSIX classes and quantifier suffixes, and `upto` to read
inline group comments. It recognizes absence group prefixes and tracks their
nesting. The experiment asks how much of the existing scanner contract can be
expressed with those facilities.

The comparator targets `Regexp::Scanner.scan` from the released
[`regexp_parser` 2.13.4 gem](https://rubygems.org/gems/regexp_parser/versions/2.13.4).
It compares every token's type, name, text, encoding, and zero-based half-open
character offsets. The prototype covers literal runs, anchors, groups and
assertion prefixes, common escapes, quantifiers, nested sets, and global
extended spacing.

## Reproduce

Download the [v2.13.4 tag](https://github.com/ammar/regexp_parser/tree/v2.13.4)
for its specs. The published gem supplies the Ragel-generated reference scanner.
Run the comparator from a Flexr checkout with the active Ruby's gem environment.

```sh
curl -fL https://codeload.github.com/ammar/regexp_parser/tar.gz/refs/tags/v2.13.4 -o /tmp/regexp_parser-v2.13.4.tar.gz
tar -xzf /tmp/regexp_parser-v2.13.4.tar.gz -C /tmp
gem install 'regexp_parser:2.13.4' 'leto:2.4.0' 'regexp_property_values:1.5.2' 'rspec:3.13.2' 'warning:1.6.0'
ruby -Ilib benchmark/regexp_parser_parity.rb /tmp/regexp_parser-2.13.4 spec/scanner
ruby -Ilib benchmark/regexp_parser_parity.rb /tmp/regexp_parser-2.13.4
```

RSpec runs upstream's examples with the released scanner. The observer
records main-Ractor scanner requests, including those sent by lexer and parser
examples. After RSpec passes, the comparator replays distinct requests based on
source bytes, encoding, Regexp flags, and the `options:` argument. The JSON
report lists counts and a small reproducer for each gap. The replay compares
returned arrays and tracks upstream errors separately. Callback behavior,
reentrant calls, other Ractors, and exact error classes and messages would need
separate prototype coverage.

## Results

Ruby 4.0.9, `regexp_parser` 2.13.4.

| Upstream specs | Passing RSpec examples | Unique requests | Exact tokens | Unsupported | Different tokens | Upstream errors |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `spec/scanner` | 821 | 552 | 239 | 221 | 0 | 92 |
| `spec` | 2,116 | 1,617 | 520 | 1,005 | 0 | 92 |

The prototype rejected all 92 requests for which the published scanner raised.
For requests that returned tokens upstream, the largest gap was Unicode
property handling. Each row below counts the first unsupported construct per
request.

| First unsupported construct | `spec/scanner` | `spec` | Example |
| --- | ---: | ---: | --- |
| Unicode property escapes | 115 | 793 | `\p{Greek}` |
| Backreferences, subexpression calls, and numeric escape ambiguity | 39 | 85 | `(a)\1` |
| Inline option switches and scoped options | 24 | 58 | `(?x:a b)` |
| Conditional groups | 18 | 34 | `(a)(?(1)b)` |
| Control and meta escapes | 22 | 29 | `\cA` |
| High-byte hex escapes and encoding | 3 | 6 | `\x94\x95` with `Regexp::NOENCODING` |

A replacement would need to preserve property alias validation, group and
option state, capture-dependent numeric escape classification, and the
scanner's error and callback contracts. These require work beyond token
recognition. This experiment measured token parity on its subset and left
performance unmeasured.
