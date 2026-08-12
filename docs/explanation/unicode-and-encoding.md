# Unicode and encoding

The automaton consumes bytes, but UTF-8 patterns are expanded into byte ranges
that respect codepoint boundaries. Binary specifications operate directly on
all 256 byte values. This separation keeps the hot path predictable while
allowing Unicode-aware patterns.

The vendored Unicode Character Database snapshot, currently 15.1.0, is the
compatibility oracle for `\p{...}`, POSIX properties where a Unicode property
is defined, Unicode shorthand behavior with `option :unicode`, and simple case
folding. Property ranges are compiled into the same DFA as ordinary rules, so
they preserve leftmost-longest matching and streaming behavior. Host Ruby
Unicode tables are not used as a cross-version oracle.

Use `encoding Encoding::BINARY` for protocol or byte-oriented formats. Use the
default UTF-8 encoding for text. A pattern with invalid UTF-8 or an input that
breaks a required boundary is rejected or reported as an unmatched byte rather
than normalized.

`rake unicode:verify` checks range ordering, scalar expansions, and deterministic
random range cases. Updating Unicode data requires regenerating generated golden
files and is documented as a minor-version compatibility change.
