# frozen_string_literal: true

require "playground/html_javascript"

class Lexer < Flexr::Lexer
  token_kind :struct

  rule(%r{<script>(?<js>(?~</script>))</script>}) do
    delegate PlaygroundJavaScriptLexer, capture: :js
  end
  rule(%r{</?[a-zA-Z][^>]*>}, emit: :HTML_TAG)
  rule(/[^<\s]+/, emit: :HTML_TEXT)
  rule(/\s+/, channel: :whitespace)
end
