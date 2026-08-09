# ADR 0001: Byte-level DFA

The lexer automaton consumes bytes. This keeps the hot path independent of
Ruby string encoding, gives invalid UTF-8 a deterministic one-byte fallback,
and enables binary region acceleration.
