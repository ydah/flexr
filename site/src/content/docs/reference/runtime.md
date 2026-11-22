---
title: Runtime reference
description: The runtime entry points and operational behavior.
---

Create a lexer with an input string or IO-like source, then call `next_token` or `each_token`.

```ruby
lexer = Lexer.new(source)
token = lexer.next_token
lexer.each_token { |type, value| consume(type, value) }
```

The runtime tracks byte position, line, column, and the last token location. Buffering and encoding behavior follow the options declared by the lexer. EOF is represented by the runtime's end-of-input result and should be normalized by a parser adapter.

## Indentation

Use `indentation` when line indentation defines blocks.
Emit a newline token and skip spaces and comments in the lexer rules.

```ruby
class LayoutLexer < Flexr::Lexer
  token_kind :struct
  indentation newline: :NEWLINE, indent: :INDENT, dedent: :DEDENT,
              brackets: %w[() [] {}], tab_width: 4
  rule(/\r?\n/, emit: :NEWLINE)
  rule(/[ \t]+/, skip: true)
  rule(/#[^\r\n]*/, skip: true)
  rule(/[a-z]+/, emit: :WORD)
  rule(/[()\[\]{}]/, emit: :BRACKET)
end

LayoutLexer.new("root\n  child\nend").tokens.map(&:type)
# => [:WORD, :NEWLINE, :INDENT, :WORD, :NEWLINE, :DEDENT, :WORD]
```

Blank and comment-only lines do not affect layout.
Newlines inside brackets are suppressed.
Structured layout tokens have a zero-width location at the next content token or at EOF.
Included inputs have their own indentation levels and emit final dedents before the parent input resumes.

See the repository's [runtime reference](https://github.com/ydah/flexr/blob/main/docs/reference/runtime.md) for constructor options, `less`, `more`, `echo`, state transitions, and error hooks.
