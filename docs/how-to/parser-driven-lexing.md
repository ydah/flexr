# Select a token using parser context

Pass `expect:` when the parser knows which terminal types it can consume.
The array applies to the next token request, including any skipped input
or trivia before that token.

## Ruby division and regexp literals

This subset handles the two meanings of `/`. At the start of an expression,
the parser can request `REGEXP`; after an operand, it can request `DIV`.

```ruby
class SlashLexer < Flexr::Lexer
  rule(/[ \t]+/, skip: true)
  rule(%r{/(?:[^/\\\n]|\\.)+/}, emit: :REGEXP)
  rule("/", emit: :DIV)
end

SlashLexer.new("/a/").next_token(expect: [:REGEXP]) # => [:REGEXP, "/a/"]
SlashLexer.new("/a/").next_token(expect: [:DIV])    # => [:DIV, "/"]
```

## JavaScript template text and expressions

The parser requests text and delimiters between backticks. After `${` it
requests expression tokens until the closing brace. This subset recognizes
a text segment and one identifier inside an interpolation.

```ruby
class TemplateLexer < Flexr::Lexer
  rule("`", emit: :BACKTICK)
  rule('${', emit: :INTERPOLATE)
  rule("}", emit: :CLOSE_BRACE)
  rule(/[a-z_][a-z_0-9]*/i, emit: :IDENT)
  rule(/(?:[^`$\\]|\\.)+/, emits: :TEMPLATE_TEXT) { emit :TEMPLATE_TEXT, text }
end

lexer = TemplateLexer.new('`hi ${name}`')
lexer.next_token(expect: [:BACKTICK])                              # => [:BACKTICK, "`"]
lexer.next_token(expect: %i[TEMPLATE_TEXT INTERPOLATE BACKTICK])   # => [:TEMPLATE_TEXT, "hi "]
lexer.next_token(expect: %i[TEMPLATE_TEXT INTERPOLATE BACKTICK])   # => [:INTERPOLATE, "${"]
lexer.next_token(expect: [:IDENT])                                 # => [:IDENT, "name"]
lexer.next_token(expect: [:CLOSE_BRACE])                            # => [:CLOSE_BRACE, "}"]
lexer.next_token(expect: %i[TEMPLATE_TEXT INTERPOLATE BACKTICK])   # => [:BACKTICK, "`"]
```

In a parser loop, compute the array from the current parser state. For a
token/value pair and the Racc EOF convention, use `racc_next_token(expect:)`.
