# frozen_string_literal: true

class PlaygroundJavaScriptLexer < Flexr::Lexer
  token_kind :struct

  rule("let", emit: :JS_LET)
  rule(/[a-zA-Z_$][a-zA-Z_$0-9]*/, emit: :JS_IDENT)
  rule(/[0-9]+/, emit: :JS_NUMBER)
  rule(/[=+\-*\/]/, emit: :JS_OPERATOR)
  rule(/[();]/, emit: :JS_PUNCTUATION)
  rule(/\s+/, channel: :whitespace)
end
