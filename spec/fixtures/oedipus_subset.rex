class OriginalLexer
macro
  DIGIT /[0-9]/
  NUMBER /#{DIGIT}+/
rule
  /a|ab/ { [:FIRST, text] }
  /ab/ { [:LONG, text] }
  /kw/i { [:KEYWORD, true] }
  /x\/y/ { [:PATH, text] }
  /#{NUMBER}/o { [:NUMBER, text.to_i] }
  /[ \t]+/
  /./ { [text, text] }
end
