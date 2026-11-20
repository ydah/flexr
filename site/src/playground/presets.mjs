export const PRESETS = {
  longest: {
    input: 'if == total',
    source: `class Lexer < Flexr::Lexer
  emits :EQ, :ASSIGN, :IF, :IDENT
  rule(/[ \\t\\n]+/, skip: true)
  rule(/==/, emit: :EQ)
  rule(/=/, emit: :ASSIGN)
  rule(/if/, emit: :IF)
  rule(/[a-z_][a-z0-9_]*/, emit: :IDENT)
end`,
  },
  calculator: {
    input: '12 + 3 * 4',
    source: `class Lexer < Flexr::Lexer
  emits :INTEGER, :PLUS, :STAR
  rule(/[ \\t\\n]+/, skip: true)
  rule(/[0-9]+/) { emit :INTEGER, text.to_i }
  rule(/\\+/, emit: :PLUS)
  rule(/\\*/, emit: :STAR)
end`,
  },
  json: {
    input: '{"ok": true, "count": 2}',
    source: `class Lexer < Flexr::Lexer
  rule(/[ \\t\\n]+/, skip: true)
  rule(/[{}:,\\[\\]]/) { emit text }
  rule(/true|false|null/, emit: :KEYWORD)
  rule(/"[^"\\n]*"/, emit: :STRING)
  rule(/[0-9]+/) { emit :NUMBER, text.to_i }
end`,
  },
};
