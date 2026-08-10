# Optional Rexical comparison specification for the JSON corpus.
# The action values intentionally mirror examples/json/lexer.flexr.rb.

class JsonRexicalLexer
  macro
    digit [0-9]
    number -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
    string "(\\.|[^"\\])*"
  end

  rule
    [ \t\r\n]+       { /* skip */ }
    \{                { return [:LBRACE, yytext] }
    \}                { return [:RBRACE, yytext] }
    \[                { return [:LBRACKET, yytext] }
    \]                { return [:RBRACKET, yytext] }
    :                 { return [:COLON, yytext] }
    ,                 { return [:COMMA, yytext] }
    true              { return [:TRUE, true] }
    false             { return [:FALSE, false] }
    null              { return [:NULL, nil] }
    {number}          { return [:NUMBER, yytext.to_f] }
    {string}          { return [:STRING, yytext[1...-1]] }
  end
end
