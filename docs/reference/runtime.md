# Runtime reference

`Flexr::Lexer` includes the runtime methods below. Runtime mode and generated
mode expose the same consumer-facing methods.

## Compilation cache

Set `Flexr.cache_dir` before compiling a specification to reuse compiled
DFA tables in later Ruby processes.

```ruby
require "flexr"

Flexr.cache_dir = "tmp/flexr-cache"
```

The cache starts disabled. Set `Flexr.cache_dir = nil` to disable it again.
Missing, corrupt, or inaccessible entries fall back to compilation.

Flexr keys each table by its patterns, rule priority, encoding and DFA
state limit, as well as the flexr and Unicode versions. It still validates
the current specification and uses its actions and diagnostics. Cache
files can be deleted at any time.

## Initialization

```ruby
Lexer.new(input,
  filename: nil,
  error_mode: :raise,
  max_token_size: 16 * 1024 * 1024,
  max_lookahead_size: nil,
  max_buffer_size: 64 * 1024 * 1024,
  max_state_stack: 1024,
  max_steps: nil,
  cancellation: nil,
  retain_input: true,
  freeze_input: true,
  chunk_size: 64 * 1024)
```

`input` must be a `String` or an object responding to `read`. `filename` is
copied into locations and lexical errors. `error_mode` is `:raise`, `:token`,
or `:panic`; unknown values raise `ArgumentError` at initialization.
`max_lookahead_size` defaults to `max_token_size`. `max_steps: nil`
leaves the step count unbounded; `cancellation` may be a callable accepting
zero arguments or the lexer. Size limits are non-negative, and `chunk_size`
must be positive.

The lexer takes a frozen snapshot of each mutable String at initialization
or when `push_input` queues it. It reuses an already frozen String.
Pass `freeze_input: false` to borrow the supplied mutable String. With
`retain_input: false`, compaction can detach the retained window from that
String. IO continues to read in chunks.

## Consumption

| Method | Result |
|---|---|
| `next_token(expect: nil)` | One default-channel token, or `nil` at EOF |
| `tokens(channels: :default)` | Array containing the remaining default-channel tokens |
| `tokens(channels: :all)` | Array containing the remaining tokens from every channel in input order |
| `each_token` | Enumerator without a block; otherwise yields tokens and returns `self` |
| `racc_next_token(expect: nil)` | `[type, value]`, or `[false, "$end"]` at EOF |
| `input` | The currently retained input string |
| `buffer` | Internal buffered input object; use only for integrations that need it |
| `filename` | The configured filename |
| `error_mode` | The configured default input error mode |
| `max_token_size` | The configured token-size limit |
| `max_lookahead_size` | The configured trailing-context limit |
| `steps` | Work units consumed by scanning |

`each_token` yields two arguments instead of one when `token_kind :yield` is
selected. `tokens` always returns an array of token values.
With trivia channels, `each_token` and `racc_next_token` expose the default
channel just like `next_token`. Collect all channels from a fresh lexer to
preserve the full stream. A lexer instance advances as tokens are consumed.
When a rule delegates, its child contributes the default-channel token stream.
Structured delegated tokens preserve the child's attached trivia.
Checkpoints include queued child tokens. Seeking clears that queue.

## Parser token expectations

Pass an array of token Symbols as `expect:` to select rules for one token
request. A rule with `emit:` is eligible when its type is expected. For a
keyword-table rule, flexr checks the exact spelling at each candidate's end
and uses the resulting type. A rule with `emits:` is eligible when any of its
declared types is expected. Skip and trivia rules and action blocks without
annotations remain eligible. Use `nil` to make every rule eligible.

Flexr applies the backend's usual ordering to eligible matches. For a
longest-match lexer this includes trailing context and the usual tie
breakers. A `firstmatch` lexer retains Ruby regexp alternative order and rule
order. If no eligible rule matches input, normal error recovery applies.
EOF actions also retain their normal behavior.

Expectations restrict rule selection. A dynamic action can still emit any
type it chooses, and a parser can validate the returned token in its current
state. An empty array leaves skip, trivia, and unannotated rules eligible.

In an indentation lexer, newline rules and configured bracket lexemes
remain eligible. When the parser requests an indent or dedent, the lexer
can use ordinary rule selection for the first content token of the line.
That token stays queued while the lexer returns the layout tokens. A later
expectation applies when the lexer scans new input.
See [Ruby slash and JavaScript template examples](../how-to/parser-driven-lexing.md).

## Indentation tokens

Use [`indentation`](dsl.md) to insert layout tokens as the lexer reads the
first visible token of each line. Spaces and tabs establish an indentation
width even when their rules skip them or send them to a trivia channel. The
first line starts at width zero and can introduce an indent. A dedent must
return to a previous width, or the lexer raises `Flexr::LexError` at the
first visible token of the line.

Blank lines, comment-only lines, and newlines inside configured brackets
yield no newline or layout tokens. A matching closing bracket resumes
layout processing on the next line. Trivia attached to a suppressed newline
carries forward to the next visible token. With `tokens(channels: :all)`,
trivia tokens remain visible and layout still uses the default-channel stream.

Layout tokens have a `nil` value. With `token_kind :struct`, they have a
zero-width location at the first visible token of the line. The lexer reads
that token before returning the layout tokens. At EOF, outstanding dedents
have a zero-width location at the end of the input and precede ordinary
tokens emitted by an `on_eof` action. An EOF action can emit the configured
newline to close the last line before the dedents. EOF adds no implicit newline.

## Checkpoint and seek

Use these methods between token reads.

| Method | Result |
|---|---|
| `checkpoint` | An immutable, opaque bookmark for this lexer |
| `restore(bookmark)` | Restores the bookmark and returns the lexer |
| `seek(byte_position)` | Moves to an absolute byte offset and returns the lexer |

A bookmark includes the cursor and its line and column, the lexical state and
stack, any buffered token or accumulated `more` text, and EOF and halt state.
Replay runs the same actions again. Application state and mutable token
values stay under the caller's control. Keep the input bytes unchanged while
using a bookmark. The work counter continues to count actual scanning work.

`seek` recalculates line, column, and start-of-line status without running
rules. It keeps the selected state and stack and clears the previous match,
pending token, accumulated text, halt state, and per-state EOF bookkeeping.
The next read can run an EOF action again.

For IO, both methods use the bytes the lexer already has. Checkpoints allow
the lexer to release bytes according to `retain_input`. Restore raises
`RangeError` if its cursor or accumulated text has been discarded. Seek
requires a retained byte offset with known coordinates. Its coordinate origin
is the current cursor, the beginning of the input when retained, or the start
of retained `more` text. Seek raises `RangeError` outside that range and
`ArgumentError` at an interior UTF-8 byte or a buffered edge with an
incomplete scalar. A bookmark from another lexer also raises `ArgumentError`.
On a lexer with an input stack, `seek` addresses the active input. A bookmark
can be restored only while its original input is active. It records the cursor
and playback state for that input.

An indentation lexer includes pending layout tokens and levels in its
checkpoint. `seek(0)` clears that layout state. Use a checkpoint to restore
another offset because its layout depends on preceding tokens.

## Action-free recognition

Use `Lexer.recognizer(state: :initial)` to obtain a reusable, immutable
`Flexr::Recognizer` for one lexical state. Runtime, generated, and
standalone lexers expose the same API.

```ruby
recognizer = GrammarLexer.recognizer
rule, finish = recognizer.match("word", 0)  # [:IDENTIFIER, 4]

recognizer.match("word", 0) do |identity, ending|
  consume_match(identity, ending)
end
```

The matcher starts at the given byte offset and returns the rule identity
and exclusive end byte. The identity is the symbol declared with `emit:`
or the zero-based source-rule index for other rules, including skips.
Keyword classification and dynamic actions belong to token emission.
Recognition reads the compiled tables without running actions, updating
state, or constructing a lexer instance.

Longest match includes trailing context when ranking rules, and `finish`
excludes the lookahead. Line anchors use the original string. UTF-8
recognition respects full scalar boundaries. Binary recognition operates on
bytes. A no-match result or an offset at EOF returns `nil`. A non-EOF
zero-width match requires `allow_empty_match` and can return the incoming
offset, so the caller controls progress.

The block form yields both fields and returns the block's result. It avoids
allocating the result array. A recognizer is shareable across Ractors after
construction. Build it once and reuse it for matching.

Construction accepts `table`, `direct`, and `auto` lexers and raises
`ArgumentError` for `firstmatch` or an unknown state. `match` requires a
`String` and an `Integer` byte offset. An offset outside the input raises
`RangeError`. Use `Lexer.new` for streaming, recovery, and lexer-instance
limits.

## State and action context

The public action methods are collected in the [actions reference](actions.md).
State transitions are instance-local; changing one lexer does not change the
class or another lexer instance.

## Streaming input

IO input is read lazily in chunks. UTF-8 input is checked at codepoint
boundaries, while binary input is consumed byte by byte. Invalid UTF-8 becomes
an unmatched-byte error rather than being silently normalized. With
`retain_input: false`, bytes before the current token are released after each
match; `input` and `binary_input` then expose only the retained window.

`max_token_size` is checked before an action can shorten or materialize an
oversized match. `max_lookahead_size` separately bounds trailing context, and
`max_buffer_size` bounds bytes retained at one time. `max_steps` and
`cancellation` bound CPU work cooperatively.

## Input stack

`push_input(input, filename: nil)` accepts a `String` or an object responding
to `read`. The lexer enters it at the next token boundary. A rule action can
queue an input and still emit a token using the current source and location.

```ruby
rule("@defaults") do
  push_input("enabled = true\n", filename: "defaults")
end
```

Each included input starts in `:initial` with an empty lexical state stack,
byte offset 0, and line and column 1. The given filename appears in its
token locations and lexical errors. Its normal `on_eof` action can emit
a token. Once that action finishes, the lexer resumes the suspended input
position, lexical stack, and accumulated text. If several inputs are queued
for the same boundary, the last one pushed is read first.

With indentation enabled, each input starts with a fresh layout stack.
A child emits its final dedents at its own EOF, before the lexer restores
the parent's indentation levels and bracket state. Any explicit child
EOF token follows the child's dedents, just as it does at root EOF.

Buffer and token limits apply to each input, and the work budget and error
policy are shared by the lexer. Invalid inputs and oversized strings fail
when pushed. IO is read lazily, so leave it open until the lexer has consumed
it. The caller owns the IO. A read error propagates while the failed input
is active.

Standalone generation embeds the input stack if the lexer source calls
`push_input`. Add `option :input_stack` when only external code or an
indirect call pushes inputs.
